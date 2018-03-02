
#import <simd/simd.h>

simd_float4x4 matrix_rotation_axis_angle(simd_float3 axis, float angle);

simd_float4x4 matrix_lookat(simd_float3 at, simd_float3 from, simd_float3 up);

simd_float4x4 matrix_perspective_projection(float fovY, float aspect, float nearZ, float farZ);
