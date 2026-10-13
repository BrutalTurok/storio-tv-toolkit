# Joins core.cs (ext4 and disk reader/writer in C#) into menu.ps1 -> ../StorioTV-Tool.ps1
import os
here = os.path.dirname(os.path.abspath(__file__))
core = open(os.path.join(here, 'core.cs'), encoding='utf-8').read()
m = open(os.path.join(here, 'menu.ps1'), encoding='utf-8').read()
assert "\n'@" not in core
out = m.replace('#__CORE__', core.rstrip('\n')).replace('\r\n', '\n').replace('\n', '\r\n')
open(os.path.join(here, '..', 'StorioTV-Tool.ps1'), 'w', encoding='utf-8-sig', newline='').write(out)
print('StorioTV-Tool.ps1 generated')
