
#import "MathUtilities.h"

simd_float4x4 matrix_rotation_axis_angle(simd_float3 axis, float angle) {
    float x = axis.x, y = axis.y, z = axis.z;
    float c = cosf(angle);
    float s = sinf(angle);
    float t = 1 - c;
    
    simd_float4 c0 = { t * x * x + c,     t * x * y + z * s, t * x * z - y * s, 0 };
    simd_float4 c1 = { t * x * y - z * s, t * y * y + c,     t * y * z + x * s, 0 };
    simd_float4 c2 = { t * x * z + y * s, t * y * z - x * s, t * z * z + c,     0 };
    simd_float4 c3 = {                 0,                 0,             0,     1 };
    
    return (simd_float4x4){ c0, c1, c2, c3 };
}

simd_float4x4 matrix_lookat(simd_float3 at, simd_float3 from, simd_float3 up) {
    simd_float3 toward = simd_normalize(at - from);
    simd_float3 z = -toward;
    simd_float3 x = simd_normalize(simd_cross(up, z));
    simd_float3 y = simd_cross(z, x);
    
    simd_float4 c0 = { x.x, y.x, z.x, 0 };
    simd_float4 c1 = { x.y, y.y, z.y, 0 };
    simd_float4 c2 = { x.z, y.z, z.z, 0 };
    simd_float4 c3 = { -simd_dot(x, from.x), -simd_dot(y, from.y), -simd_dot(z, from.z), 1 };
    
    return (simd_float4x4){ c0, c1, c2, c3 };
}

simd_float4x4 matrix_perspective_projection(float fovY, float aspect, float nearZ, float farZ) {
    float yscale = 1 / tanf(fovY * 0.5);
    float xscale = yscale / aspect;
    float zz = -(farZ + nearZ) / (farZ - nearZ);
    float zw = -(2 * farZ * nearZ) / (farZ - nearZ);
    
    simd_float4x4 m = {
        .columns[0] = { xscale,  0, 0,  0 },
        .columns[1] = { 0, -yscale, 0,  0 },
        .columns[2] = { 0, 0,      zz, -1 },
        .columns[3] = { 0, 0,      zw,  0 }
    };
    
    return m;
}
