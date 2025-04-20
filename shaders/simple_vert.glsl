#version 450

// vec3 grid_planes[6] = vec3[](
//     vec3(1, 1, 0), vec3(-1, -1, 0), vec3(-1, 1, 0),
//     vec3(-1, -1, 0), vec3(1, 1, 0), vec3(1, -1, 0)
// );
//
// void main() {
//     gl_Position = vec4(grid_planes[gl_VertexIndex], 1.0);
// }

vec2 positions[3] = vec2[](
    vec2(0.0, -0.5),
    vec2(0.5, 0.5),
    vec2(-0.5, 0.5)
);

void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
