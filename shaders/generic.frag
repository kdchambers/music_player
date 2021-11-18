#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(binding = 0) uniform sampler2DArray samplerArray;

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = (inTexCoord.x != 9.0) ? texture(samplerArray, vec3(mod(inTexCoord, 1.0001), inTexCoord.x / 2)) * inColor : inColor;
}
