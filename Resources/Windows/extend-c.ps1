# Runs at every boot: grows C: into space added with "tart set --disk-size".
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($max -gt (Get-Partition -DriveLetter C).Size) {
  Resize-Partition -DriveLetter C -Size $max
}
