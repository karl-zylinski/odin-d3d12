package render

Handle :: distinct u64

WindowHandle :: distinct u64

TextureFormat :: enum {
    Unknown,
    R8G8B8A8_UNORM,
}

texture_size :: proc(format: TextureFormat, width: int, height: int) -> int {
    switch format {
        case .Unknown: return 0
        case .R8G8B8A8_UNORM: return width * height * 4
    }
    return 0
}
