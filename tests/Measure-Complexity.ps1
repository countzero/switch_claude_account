#Requires -Version 7.4
<#
.SYNOPSIS
    Per-function complexity diagnostic for switch_claude_account.ps1.

.DESCRIPTION
    Walks the PowerShell AST and reports LOC, McCabe cyclomatic complexity,
    and maximum nesting depth for every function definition. Sorted by CC
    descending. Rows with CC >= 10 (McCabe canonical / NIST SP 500-235
    primary threshold) or MaxNest >= 4 (ESLint max-depth default) are
    flagged with `!`.

    Pure advisory diagnostic. Always exits 0. No baseline file, no
    regression detection, no test-runner integration.

    CC counting (McCabe-style):
      base 1
      + IfStatementAst.Clauses.Count       (each if/elseif arm)
      + SwitchStatementAst.Clauses.Count   (each case arm; default omitted)
      + 1 per loop AST                     (foreach, for, while, do-while, do-until)
      + TryStatementAst.CatchClauses.Count (each catch arm)
      + 1 per BinaryExpressionAst with -and / -or
      + 1 per TernaryExpressionAst (PS 7+)

    MaxNest counts the deepest stack of (If/Switch/loops/Try) ancestors
    for any node within the function body, scoped to the function itself
    (nodes inside nested function definitions are excluded).

.EXAMPLE
    pwsh -NoProfile -File tests/Measure-Complexity.ps1
#>
[CmdletBinding()]
Param ()

$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Warning "Parse errors:"
    foreach ($e in $errors) { Write-Warning "  $($e.Message) at line $($e.Extent.StartLineNumber)" }
}

# Type set used for both CC accumulation (where each contributes per-clause)
# and nesting-depth tracking (where each pushes one level).
$nestingTypes = @(
    [System.Management.Automation.Language.IfStatementAst],
    [System.Management.Automation.Language.SwitchStatementAst],
    [System.Management.Automation.Language.ForEachStatementAst],
    [System.Management.Automation.Language.ForStatementAst],
    [System.Management.Automation.Language.WhileStatementAst],
    [System.Management.Automation.Language.DoWhileStatementAst],
    [System.Management.Automation.Language.DoUntilStatementAst],
    [System.Management.Automation.Language.TryStatementAst]
)

# Returns the nearest enclosing FunctionDefinitionAst for any AST node, or
# $null for top-level nodes. Used to scope per-function metrics so nodes
# inside nested function definitions don't bleed into the outer counts.
function Get-EnclosingFunction {
    Param ($Node)
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
        $p = $p.Parent
    }
    return $null
}

function Test-IsNestingNode {
    Param ($Node)
    foreach ($t in $nestingTypes) {
        if ($Node -is $t) { return $true }
    }
    return $false
}

function Get-FunctionMetrics {
    Param ([System.Management.Automation.Language.FunctionDefinitionAst] $Func)

    $cc = 1

    # If clauses: each `if` / `elseif` arm counts; trailing `else` does not
    # (it's the fall-through, not a separate decision).
    $ifs = $Func.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] }, $true) |
        Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    foreach ($i in $ifs) { $cc += $i.Clauses.Count }

    # Switch clauses: each case arm counts; `default` is fall-through and excluded.
    $switches = $Func.FindAll({ $args[0] -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) |
        Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    foreach ($s in $switches) { $cc += $s.Clauses.Count }

    # Loops: each contributes +1.
    $loops = $Func.FindAll({
        $n = $args[0]
        $n -is [System.Management.Automation.Language.ForEachStatementAst] -or
        $n -is [System.Management.Automation.Language.ForStatementAst] -or
        $n -is [System.Management.Automation.Language.WhileStatementAst] -or
        $n -is [System.Management.Automation.Language.DoWhileStatementAst] -or
        $n -is [System.Management.Automation.Language.DoUntilStatementAst]
    }, $true) | Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    $cc += @($loops).Count

    # Try/Catch: each catch arm counts (the `try` itself is +0; the catches
    # are the branch points).
    $tries = $Func.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
        Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    foreach ($t in $tries) { $cc += $t.CatchClauses.Count }

    # Boolean -and / -or short-circuit operators each create a branch.
    $bins = $Func.FindAll({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true) |
        Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    foreach ($b in $bins) {
        if ($b.Operator -eq 'And' -or $b.Operator -eq 'Or') { $cc++ }
    }

    # Ternary (PS 7+) is a single decision.
    $ternaries = $Func.FindAll({ $args[0] -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true) |
        Where-Object { (Get-EnclosingFunction $_) -eq $Func }
    $cc += @($ternaries).Count

    # MaxNest: depth of the deepest nesting node (counting itself + all
    # nesting-typed ancestors up to but not crossing the function boundary).
    $maxNest = 0
    $nestingNodes = $Func.FindAll({
        $n = $args[0]
        ($n -is [System.Management.Automation.Language.IfStatementAst]) -or
        ($n -is [System.Management.Automation.Language.SwitchStatementAst]) -or
        ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -or
        ($n -is [System.Management.Automation.Language.ForStatementAst]) -or
        ($n -is [System.Management.Automation.Language.WhileStatementAst]) -or
        ($n -is [System.Management.Automation.Language.DoWhileStatementAst]) -or
        ($n -is [System.Management.Automation.Language.DoUntilStatementAst]) -or
        ($n -is [System.Management.Automation.Language.TryStatementAst])
    }, $true) | Where-Object { (Get-EnclosingFunction $_) -eq $Func }

    foreach ($n in $nestingNodes) {
        $depth = 1
        $p = $n.Parent
        while ($p -and $p -ne $Func) {
            if (Test-IsNestingNode $p) { $depth++ }
            $p = $p.Parent
        }
        if ($depth -gt $maxNest) { $maxNest = $depth }
    }

    return [pscustomobject]@{
        Name      = $Func.Name
        LOC       = $Func.Extent.EndLineNumber - $Func.Extent.StartLineNumber + 1
        CC        = $cc
        MaxNest   = $maxNest
        StartLine = $Func.Extent.StartLineNumber
        EndLine   = $Func.Extent.EndLineNumber
    }
}

$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$results = foreach ($f in $funcs) { Get-FunctionMetrics -Func $f }

# Sort by CC desc, tiebreak by MaxNest desc, then LOC desc.
$results = $results | Sort-Object `
    @{Expression='CC';      Descending=$true}, `
    @{Expression='MaxNest'; Descending=$true}, `
    @{Expression='LOC';     Descending=$true}

# Output
$nameW = 8  # min header width for "Function"
foreach ($r in $results) { if ($r.Name.Length -gt $nameW) { $nameW = $r.Name.Length } }

$fmt = "  {0} {1,-$nameW}  {2,5}  {3,4}  {4,4}  {5}"
Write-Host ""
Write-Host "Per-function complexity report" -ForegroundColor DarkYellow
Write-Host "Source: $scriptPath"
Write-Host ""
Write-Host ($fmt -f ' ', 'Function', 'LOC', 'CC', 'Nest', 'Range')
Write-Host ($fmt -f ' ', ('-' * $nameW), '-----', '----', '----', '-----')
foreach ($r in $results) {
    $flag = if ($r.CC -ge 10 -or $r.MaxNest -ge 4) { '!' } else { ' ' }
    $range = "{0}-{1}" -f $r.StartLine, $r.EndLine
    $line  = $fmt -f $flag, $r.Name, $r.LOC, $r.CC, $r.MaxNest, $range
    if ($flag -eq '!') {
        Write-Host $line -ForegroundColor Yellow
    } else {
        Write-Host $line
    }
}

$total   = @($results).Count
$flagged = @($results | Where-Object { $_.CC -ge 10 -or $_.MaxNest -ge 4 }).Count
Write-Host ""
Write-Host "Total: $total functions, $flagged flagged (CC >= 10 or Nest >= 4)"
Write-Host ""

exit 0
