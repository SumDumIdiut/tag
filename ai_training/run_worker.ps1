Set-Location -Path $PSScriptRoot
& "C:\Users\Flipped\AppData\Local\Programs\Python\Python312\python.exe" -u worker.py --learner http://192.168.1.115:8770 --envs 768 --poll-interval 2.0 *>> (Join-Path $PSScriptRoot "worker.log")
