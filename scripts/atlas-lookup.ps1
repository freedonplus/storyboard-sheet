# atlas-lookup.ps1
# 检索可填提示词图集 master/prompt-atlas.json（结构：提示词 → 树形节点，叶子含 值/_opt/_en/_hint/_ref）。
# 兼容 Windows PowerShell 5.1（无 ??、三元、&&）。输出统一为 Markdown 片段。
#
# 用法示例：
#   .\atlas-lookup.ps1 -Outline                          # 列出全部一级分卷 + 子节点数 + 选项总数
#   .\atlas-lookup.ps1 -Outline -Path "摄影层"           # 列出某分卷下的子节点
#   .\atlas-lookup.ps1 -Path "摄影层/焦段镜头"           # 输出该节点的全部可填叶子
#   .\atlas-lookup.ps1 -Query "推轨,dolly,环绕"          # 全库模糊搜（多词用逗号合并，中英都写命中更多）
#   .\atlas-lookup.ps1 -Query "手持" -Path "运动与时间_视频"  # 限定子树内搜
#
# 注意：powershell -File 模式下 -Query 的多个词必须合并成一个参数（逗号分隔），
#       写成 -Query "a","b","c" 会被绑定到后面的位置参数上。

[CmdletBinding()]
param(
    [string]$Path,
    [string[]]$Query,
    [switch]$Outline,
    [int]$MaxHits = 40,
    [string]$AtlasPath
)

$ErrorActionPreference = 'Stop'

# -File 模式下多词以 "a,b,c" 形式合并传入；此处统一按中英逗号拆分成词表
if ($Query) {
    $Query = @($Query | ForEach-Object { $_ -split '[,，]' } | Where-Object { $_ -and $_.Trim() })
}

# PowerShell 5.1 下让中文输出走 UTF-8，避免控制台按 GBK 编码出乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $AtlasPath) {
    $AtlasPath = Join-Path $PSScriptRoot '..\master\prompt-atlas.json'
}
if (-not (Test-Path -LiteralPath $AtlasPath -PathType Leaf)) {
    Write-Output ("ERROR: atlas file not found: {0}" -f $AtlasPath)
    exit 2
}

$resolved = (Resolve-Path -LiteralPath $AtlasPath).ProviderPath
$raw = [System.IO.File]::ReadAllText($resolved, [System.Text.Encoding]::UTF8)
$atlas = $raw | ConvertFrom-Json
$root = $atlas.提示词

if ($null -eq $root) {
    Write-Output "ERROR: atlas has no 提示词 root node."
    exit 2
}

# 递归收集叶子（含 值 字段的节点），继承最近的 _ref
function Get-Leaves {
    param($Node, [string]$BasePath, [string]$InheritedRef)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Node -or -not ($Node -is [System.Management.Automation.PSCustomObject])) { return $out }

    $curRef = $InheritedRef
    $refProp = $Node.PSObject.Properties['_ref']
    if ($refProp) { $curRef = [string]$refProp.Value }

    $valProp = $Node.PSObject.Properties['值']
    if ($valProp) {
        [void]$out.Add(@{ Path = $BasePath; Leaf = $Node; Ref = $curRef })
        return ,$out   # 逗号包装，防止 PS 5.1 把单元素 ArrayList 解包成标量
    }
    foreach ($prop in $Node.PSObject.Properties) {
        if ($prop.Name.StartsWith('_')) { continue }
        if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $sub = Get-Leaves -Node $prop.Value -BasePath ($BasePath + '/' + $prop.Name) -InheritedRef $curRef
            foreach ($s in $sub) { [void]$out.Add($s) }
        }
    }
    return ,$out
}

# 按路径逐级下钻（路径段用 / 分隔）
function Resolve-Node {
    param($Node, [string]$PathStr)
    if ([string]::IsNullOrWhiteSpace($PathStr)) { return $Node }
    $cur = $Node
    foreach ($seg in ($PathStr -split '/')) {
        if (-not ($cur -is [System.Management.Automation.PSCustomObject])) { return $null }
        $prop = $cur.PSObject.Properties[$seg]
        if (-not $prop) { return $null }
        $cur = $prop.Value
    }
    return $cur
}

function Get-OptCount {
    param($Leaves)
    $n = 0
    foreach ($l in $Leaves) {
        $opt = $l.Leaf.PSObject.Properties['_opt']
        if ($opt -and $opt.Value) { $n += @($opt.Value).Count }
    }
    return $n
}

# ---- -Outline 模式 ----
if ($Outline) {
    Write-Output ("FILE: {0}" -f $resolved)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        # -Outline -Path：列出该节点下的直接子节点
        $node = Resolve-Node -Node $root -PathStr $Path
        if ($null -eq $node) {
            Write-Output ("ERROR: path not found: {0}" -f $Path)
            exit 3
        }
        $refProp = $node.PSObject.Properties['_ref']
        $nodeRef = ''
        if ($refProp) { $nodeRef = [string]$refProp.Value }
        $hintProp = $node.PSObject.Properties['_hint']
        Write-Output ("### 节点 {0}（_ref: {1}）下的子节点" -f $Path, $nodeRef)
        if ($hintProp) { Write-Output ("_hint: {0}" -f $hintProp.Value) }
        Write-Output ""
        $found = $false
        foreach ($prop in $node.PSObject.Properties) {
            if ($prop.Name.StartsWith('_')) { continue }
            $sub = Get-Leaves -Node $prop.Value -BasePath ($Path + '/' + $prop.Name) -InheritedRef $nodeRef
            if ($sub.Count -gt 0) {
                $found = $true
                Write-Output ("- **{0}/{1}** — 叶子 {2} · 选项 {3}" -f $Path, $prop.Name, $sub.Count, (Get-OptCount $sub))
            }
        }
        if (-not $found) { Write-Output "(该节点没有子节点，本身即可填叶子；用 -Path \"{0}\" 查看明细)" -f $Path }
        exit 0
    }

    # -Outline：全库一级分卷总览
    Write-Output ""
    Write-Output "## 图集结构总览（提示词 树 · 一级分卷）"
    Write-Output ""
    Write-Output "| 一级分卷 | _ref | 叶子 | 选项 |"
    Write-Output "|---|---|---|---|"
    foreach ($prop in $root.PSObject.Properties) {
        $sub = Get-Leaves -Node $prop.Value -BasePath $prop.Name -InheritedRef ''
        $ref = ''
        if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $rp = $prop.Value.PSObject.Properties['_ref']
            if ($rp) { $ref = [string]$rp.Value }
        }
        Write-Output ("| {0} | {1} | {2} | {3} |" -f $prop.Name, $ref, $sub.Count, (Get-OptCount $sub))
    }
    Write-Output ""
    Write-Output "TIP: -Outline -Path <一级分卷名> 看子节点；-Path <路径> 看叶子明细；-Query 搜词。"
    exit 0
}

# ---- -Query 模式 ----
if ($Query -and $Query.Count -gt 0) {
    $terms = $Query | Where-Object { $_ -and $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() }
    if ($terms.Count -eq 0) {
        Write-Output "ERROR: empty query."
        exit 4
    }
    $pattern = ($terms | ForEach-Object { [regex]::Escape($_) }) -join '|'

    $scopeName = '全库'
    $baseRef = ''
    $startNode = $root
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $startNode = Resolve-Node -Node $root -PathStr $Path
        if ($null -eq $startNode) {
            Write-Output ("ERROR: path not found: {0}" -f $Path)
            exit 3
        }
        $scopeName = $Path
    }
    $leaves = Get-Leaves -Node $startNode -BasePath $Path -InheritedRef ''

    Write-Output ("FILE: {0}" -f $resolved)
    Write-Output ("QUERY: {0}　SCOPE: {1}" -f ($terms -join ' | '), $scopeName)
    Write-Output ""

    $hits = 0
    foreach ($l in $leaves) {
        if ($hits -ge $MaxHits) {
            Write-Output ("... 命中超过 {0} 条，收窄关键词或提高 -MaxHits。" -f $MaxHits)
            break
        }
        $leaf = $l.Leaf
        $matched = New-Object System.Collections.ArrayList

        $valProp = $leaf.PSObject.Properties['值']
        if ($valProp -and ([string]$valProp.Value) -match $pattern) { [void]$matched.Add(("值=" + $valProp.Value)) }
        $enProp = $leaf.PSObject.Properties['_en']
        if ($enProp -and ([string]$enProp.Value) -match $pattern) { [void]$matched.Add(("_en=" + $enProp.Value)) }
        $hintProp = $leaf.PSObject.Properties['_hint']
        if ($hintProp -and ([string]$hintProp.Value) -match $pattern) { [void]$matched.Add(("_hint=" + $hintProp.Value)) }

        $optProp = $leaf.PSObject.Properties['_opt']
        if ($optProp -and $optProp.Value) {
            foreach ($o in @($optProp.Value)) {
                if ([string]$o -match $pattern) { [void]$matched.Add([string]$o) }
            }
        }
        if ($l.Path -match $pattern) { [void]$matched.Add("(节点路径命中)") }
        if ($matched.Count -eq 0) { continue }

        $hits++
        $shown = $matched
        if ($shown.Count -gt 8) { $shown = @($matched[0..7]) + @("...") }
        Write-Output ("- ``{0}`` （_ref: {1}）→ 命中: {2}" -f $l.Path, $l.Ref, ($shown -join " ｜ "))
    }
    if ($hits -eq 0) {
        Write-Output "NO HIT. 换个说法再试，或先用 -Outline 定位分卷；atlas 没有就去主文档用 lookup-master.ps1。"
    }
    Write-Output ""
    Write-Output ("TOTAL: {0} hit(s)" -f $hits)
    exit 0
}

# ---- -Path 模式：列出节点下全部可填叶子 ----
if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $node = Resolve-Node -Node $root -PathStr $Path
    if ($null -eq $node) {
        Write-Output ("ERROR: path not found: {0}" -f $Path)
        exit 3
    }
    $leaves = Get-Leaves -Node $node -BasePath $Path -InheritedRef ''
    Write-Output ("FILE: {0}" -f $resolved)
    Write-Output ("### 节点 {0} — 共 {1} 个可填叶子 · {2} 个选项" -f $Path, $leaves.Count, (Get-OptCount $leaves))
    Write-Output ""
    foreach ($l in $leaves) {
        $leaf = $l.Leaf
        Write-Output ("#### {0}" -f $l.Path)
        $valProp = $leaf.PSObject.Properties['值']
        $val = '(空)'
        if ($valProp -and -not [string]::IsNullOrWhiteSpace([string]$valProp.Value)) { $val = [string]$valProp.Value }
        Write-Output ("- 值: {0}" -f $val)
        $enProp = $leaf.PSObject.Properties['_en']
        if ($enProp) { Write-Output ("- _en: {0}" -f $enProp.Value) }
        $hintProp = $leaf.PSObject.Properties['_hint']
        if ($hintProp) { Write-Output ("- _hint: {0}" -f $hintProp.Value) }
        $optProp = $leaf.PSObject.Properties['_opt']
        if ($optProp -and $optProp.Value) {
            Write-Output ("- _opt: {0}" -f ((@($optProp.Value) -join " ／ ")))
        }
        Write-Output ("- _ref: {0}" -f $l.Ref)
        Write-Output ""
    }
    exit 0
}

Write-Output "ERROR: give -Query, -Path, or -Outline. Examples in the header comments."
exit 4
