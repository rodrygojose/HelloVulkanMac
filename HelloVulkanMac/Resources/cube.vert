#version 400

#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable

layout (std140, binding = 0) uniform buf {
    mat4 modelViewProjectionMatrix;
    mat4 normalMatrix;
    vec4 positions[12 * 3];
    vec4 normals[12 * 3];
    vec4 texCoords[12 * 3];
} uniforms;

layout (location = 0) out vec4 texCoords;
layout (location = 1) out vec4 normal;

void main() 
{
    texCoords = uniforms.texCoords[gl_VertexIndex];
    normal = uniforms.normalMatrix * uniforms.normals[gl_VertexIndex];
    gl_Position = uniforms.modelViewProjectionMatrix * uniforms.positions[gl_VertexIndex];
}
