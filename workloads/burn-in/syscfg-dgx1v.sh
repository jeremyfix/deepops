GPU_AFFINITY="0:1:2:3:4:5:6:7"
CPU_AFFINITY="0-4:5-9:10-14:15-19:20-24:25-29:30-34:35-39"
CPU_CORES_PER_RANK=4
MEM_AFFINITY="0:0:0:0:1:1:1:1"
UCX_AFFINITY="mlx5_0:mlx5_0:mlx5_1:mlx5_1:mlx5_2:mlx5_2:mlx5_3:mlx5_3"
GPU_CLOCK="877,1530"
export LD_LIBRARY_PATH="/usr/local/cuda/compat:$LD_LIBRARY_PATH"
