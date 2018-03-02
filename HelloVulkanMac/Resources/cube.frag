#version 400

#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable

layout (binding = 1) uniform sampler2D diffuseTexture;

layout (location = 0) in vec4 texCoords;
layout (location = 1) in vec4 normal;

layout (location = 0) out vec4 uFragColor;

void main() {
    float ambient = 0.1;
    vec3 lightDir = normalize(vec3(1, 1, 1));
    float illum = clamp(dot(lightDir, normalize(normal.xyz)), 0, 1);
    vec3 color = (ambient + illum) * texture(diffuseTexture, texCoords.xy).rgb;
    uFragColor = vec4(color, 1);
}
