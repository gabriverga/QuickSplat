# Usage: python3 tools/gen_big_splat.py <out.ply> <num_splats>  (needs numpy)
import numpy as np, sys
rng = np.random.default_rng(2)
n = int(sys.argv[2])
P = rng.normal(0, 1, (n, 3)).astype(np.float32)
data = np.zeros((n, 62), np.float32)
data[:, :3] = P
data[:, 6:9] = rng.normal(0, 1, (n, 3))
data[:, 9:54] = rng.normal(0, 0.05, (n, 45))
data[:, 54] = 2.0
data[:, 55:58] = np.log(0.01)
data[:, 58] = 1.0
props = ['x','y','z','nx','ny','nz','f_dc_0','f_dc_1','f_dc_2'] + [f'f_rest_{i}' for i in range(45)] + ['opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3']
hdr = "ply\nformat binary_little_endian 1.0\nelement vertex %d\n" % n + "".join(f"property float {p}\n" for p in props) + "end_header\n"
with open(sys.argv[1], "wb") as f:
    f.write(hdr.encode()); f.write(data.astype('<f4').tobytes())
