#version 450
layout(location = 0) in vec3 inPosition;
layout(location = 1) in mat4 inInstanceMatrix;

void main() {
    gl_Position = inInstanceMatrix * vec4(inPosition, 1.0);
}