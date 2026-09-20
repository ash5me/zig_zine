const cube_vertices: []const f32 = &[_]f32{
    // Positions for a cube centered at origin with size 2 (from -1 to 1)
    -1.0, -1.0, -1.0, // 0
     1.0, -1.0, -1.0, // 1
     1.0,  1.0, -1.0, // 2
    -1.0,  1.0, -1.0, // 3
    -1.0, -1.0,  1.0, // 4
     1.0, -1.0,  1.0, // 5
     1.0,  1.0,  1.0, // 6
    -1.0,  1.0,  1.0, // 7
};

const cube_indices: []const u32 = &[_]u32{
    0,1,2, 2,3,0, // front
    1,5,6, 6,2,1, // right
    5,4,7, 7,6,5, // back
    4,0,3, 3,7,4, // left
    3,2,6, 6,7,3, // top
    4,5,1, 1,0,4, // bottom
};