import os, sys, sysconfig, numpy
b = sys.base_prefix
print(os.path.join(b, 'Include'))
print(os.path.join(b, 'libs', 'python' + str(sys.version_info[0]) + str(sys.version_info[1]) + '.lib'))
print(numpy.get_include())
print(sysconfig.get_paths()['purelib'])
