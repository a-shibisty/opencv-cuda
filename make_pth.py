import os, sys, sysconfig
dlls = [d for d in sys.argv[1:] if d and os.path.isdir(d)]
pth = os.path.join(sysconfig.get_paths()['purelib'], 'opencv_cuda.pth')
with open(pth, 'w') as f:
    f.write('import os; [os.add_dll_directory(d) for d in ' + repr(dlls) + ' if os.path.isdir(d)]\n')
print('wrote', pth)
