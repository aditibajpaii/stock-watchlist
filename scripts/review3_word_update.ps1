# review3_word_update.ps1 - open a .docx in Microsoft Word, update the table of
# contents and all fields, save it, and also save a PDF next to it.
#   powershell -ExecutionPolicy Bypass -File scripts/review3_word_update.ps1 "Review 3 Report.docx"
param([Parameter(Mandatory)] [string]$Docx)
$path = (Resolve-Path $Docx).Path
$pdf = [IO.Path]::ChangeExtension($path, ".pdf")
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
try {
    $doc = $word.Documents.Open($path)
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Fields.Update() | Out-Null
    foreach ($toc in $doc.TablesOfContents) { $toc.UpdatePageNumbers() }
    $doc.Save()
    $doc.SaveAs2($pdf, 17)   # 17 = wdFormatPDF
    "pages: " + $doc.ComputeStatistics(2)
    $doc.Close($false)
} finally {
    $word.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word)
}
"saved $path and $pdf"
