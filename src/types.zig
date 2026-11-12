//! The parsed glTF: one type for each of cgltf's structs, with the same
//! fields in the same order. cgltf's pointers between objects are indices
//! here (`?u32`, or `u32` where glTF requires the reference), into the
//! `Gltf` array of that kind; a channel's sampler is an index into its
//! animation's samplers. An array with a count is a slice.

const std = @import("std");

/// The index stored while parsing for a reference that is out of range
/// whatever the arrays hold: a negative index, or a required one that is
/// missing. A successful parse leaves none.
pub const invalid_index = std.math.maxInt(u32);

pub const FileType = enum(u32) {
    /// Detect from the first four bytes.
    invalid = 0,
    gltf = 1,
    glb = 2,
};

pub const BufferViewType = enum(u32) {
    invalid = 0,
    indices = 1,
    vertices = 2,
};

pub const AttributeType = enum(u32) {
    invalid = 0,
    position = 1,
    normal = 2,
    tangent = 3,
    texcoord = 4,
    color = 5,
    joints = 6,
    weights = 7,
    custom = 8,
};

pub const ComponentType = enum(u32) {
    invalid = 0,
    /// BYTE
    r_8 = 1,
    /// UNSIGNED_BYTE
    r_8u = 2,
    /// SHORT
    r_16 = 3,
    /// UNSIGNED_SHORT
    r_16u = 4,
    /// UNSIGNED_INT
    r_32u = 5,
    /// FLOAT
    r_32f = 6,
};

pub const Type = enum(u32) {
    invalid = 0,
    scalar = 1,
    vec2 = 2,
    vec3 = 3,
    vec4 = 4,
    mat2 = 5,
    mat3 = 6,
    mat4 = 7,
};

pub const PrimitiveType = enum(u32) {
    invalid = 0,
    points = 1,
    lines = 2,
    line_loop = 3,
    line_strip = 4,
    triangles = 5,
    triangle_strip = 6,
    triangle_fan = 7,
};

pub const AlphaMode = enum(u32) {
    @"opaque" = 0,
    mask = 1,
    blend = 2,
};

pub const AnimationPathType = enum(u32) {
    invalid = 0,
    translation = 1,
    rotation = 2,
    scale = 3,
    weights = 4,
};

pub const InterpolationType = enum(u32) {
    linear = 0,
    step = 1,
    cubic_spline = 2,
};

pub const CameraType = enum(u32) {
    invalid = 0,
    perspective = 1,
    orthographic = 2,
};

pub const LightType = enum(u32) {
    invalid = 0,
    directional = 1,
    point = 2,
    spot = 3,
};

pub const DataFreeMethod = enum(u32) {
    none = 0,
    file_release = 1,
    memory_free = 2,
};

/// The glTF number as written, whatever it is: the file's integer is kept
/// even when it names no filter.
pub const FilterType = enum(i32) {
    undefined = 0,
    nearest = 9728,
    linear = 9729,
    nearest_mipmap_nearest = 9984,
    linear_mipmap_nearest = 9985,
    nearest_mipmap_linear = 9986,
    linear_mipmap_linear = 9987,
    _,
};

/// The glTF number as written, as `FilterType` is.
pub const WrapMode = enum(i32) {
    clamp_to_edge = 33071,
    mirrored_repeat = 33648,
    repeat = 10497,
    _,
};

pub const MeshoptCompressionMode = enum(u32) {
    invalid = 0,
    attributes = 1,
    triangles = 2,
    indices = 3,
};

pub const MeshoptCompressionFilter = enum(u32) {
    none = 0,
    octahedral = 1,
    quaternion = 2,
    exponential = 3,
    color = 4,
};

/// An object's `extras`, kept as JSON text.
pub const Extras = struct {
    /// Byte offsets of the JSON value in `Gltf.json`. cgltf marks them
    /// deprecated in favour of `data`; `copyExtrasJson` reads them.
    start_offset: usize = 0,
    end_offset: usize = 0,
    /// The JSON value's text; a string's without its quotes. A mesh's is
    /// always null, as cgltf leaves it.
    data: ?[:0]u8 = null,
};

/// An extension cgltf does not parse itself: its name and its JSON object.
pub const Extension = struct {
    name: [:0]u8,
    data: [:0]u8,
};

pub const Buffer = struct {
    name: ?[:0]u8 = null,
    size: usize = 0,
    uri: ?[:0]u8 = null,
    /// Set by `loadBuffers`. For a GLB's first buffer, the whole BIN chunk,
    /// which can be longer than `size`; otherwise `size` bytes.
    data: ?[]const u8 = null,
    data_free_method: DataFreeMethod = .none,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const MeshoptCompression = struct {
    /// Set when the buffer view has the compression.
    buffer: ?u32 = null,
    offset: usize = 0,
    size: usize = 0,
    stride: usize = 0,
    count: usize = 0,
    mode: MeshoptCompressionMode = .invalid,
    filter: MeshoptCompressionFilter = .none,
    is_khr: bool = false,
};

pub const BufferView = struct {
    name: ?[:0]u8 = null,
    buffer: u32 = invalid_index,
    offset: usize = 0,
    size: usize = 0,
    /// 0 lets the accessor's element size decide.
    stride: usize = 0,
    type: BufferViewType = .invalid,
    /// Decoded data to read in place of the buffer's, such as a meshopt
    /// decoder's output. Never set by the parser and never freed by
    /// `Gltf.deinit`: it must outlive the `Gltf`, or come from
    /// `Gltf.arena`.
    data: ?[]const u8 = null,
    has_meshopt_compression: bool = false,
    meshopt_compression: MeshoptCompression = .{},
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const AccessorSparse = struct {
    count: usize = 0,
    /// Set when the accessor is sparse.
    indices_buffer_view: ?u32 = null,
    indices_byte_offset: usize = 0,
    indices_component_type: ComponentType = .invalid,
    /// Set when the accessor is sparse.
    values_buffer_view: ?u32 = null,
    values_byte_offset: usize = 0,
};

pub const Accessor = struct {
    name: ?[:0]u8 = null,
    component_type: ComponentType = .invalid,
    normalized: bool = false,
    type: Type = .invalid,
    offset: usize = 0,
    count: usize = 0,
    /// The buffer view's stride, or the element size when that is 0.
    stride: usize = 0,
    buffer_view: ?u32 = null,
    has_min: bool = false,
    min: [16]f32 = @splat(0),
    has_max: bool = false,
    max: [16]f32 = @splat(0),
    is_sparse: bool = false,
    sparse: AccessorSparse = .{},
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Attribute = struct {
    name: [:0]u8 = &.{},
    type: AttributeType = .invalid,
    /// The set number after the underscore, as `TEXCOORD_1`.
    index: i32 = 0,
    /// The accessor.
    data: u32 = invalid_index,
};

pub const Image = struct {
    name: ?[:0]u8 = null,
    uri: ?[:0]u8 = null,
    buffer_view: ?u32 = null,
    mime_type: ?[:0]u8 = null,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Sampler = struct {
    name: ?[:0]u8 = null,
    mag_filter: FilterType = .undefined,
    min_filter: FilterType = .undefined,
    wrap_s: WrapMode = @fromBackingInt(0),
    wrap_t: WrapMode = @fromBackingInt(0),
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Texture = struct {
    name: ?[:0]u8 = null,
    image: ?u32 = null,
    sampler: ?u32 = null,
    has_basisu: bool = false,
    basisu_image: ?u32 = null,
    has_webp: bool = false,
    webp_image: ?u32 = null,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const TextureTransform = struct {
    offset: [2]f32 = @splat(0),
    rotation: f32 = 0,
    scale: [2]f32 = @splat(0),
    has_texcoord: bool = false,
    texcoord: i32 = 0,
};

pub const TextureView = struct {
    texture: ?u32 = null,
    texcoord: i32 = 0,
    /// `strength` for an occlusion texture.
    scale: f32 = 0,
    has_transform: bool = false,
    transform: TextureTransform = .{},
};

pub const PbrMetallicRoughness = struct {
    base_color_texture: TextureView = .{},
    metallic_roughness_texture: TextureView = .{},
    base_color_factor: [4]f32 = @splat(0),
    metallic_factor: f32 = 0,
    roughness_factor: f32 = 0,
};

pub const PbrSpecularGlossiness = struct {
    diffuse_texture: TextureView = .{},
    specular_glossiness_texture: TextureView = .{},
    diffuse_factor: [4]f32 = @splat(0),
    specular_factor: [3]f32 = @splat(0),
    glossiness_factor: f32 = 0,
};

pub const Clearcoat = struct {
    clearcoat_texture: TextureView = .{},
    clearcoat_roughness_texture: TextureView = .{},
    clearcoat_normal_texture: TextureView = .{},
    clearcoat_factor: f32 = 0,
    clearcoat_roughness_factor: f32 = 0,
};

pub const Transmission = struct {
    transmission_texture: TextureView = .{},
    transmission_factor: f32 = 0,
};

pub const Ior = struct {
    ior: f32 = 0,
};

pub const Specular = struct {
    specular_texture: TextureView = .{},
    specular_color_texture: TextureView = .{},
    specular_color_factor: [3]f32 = @splat(0),
    specular_factor: f32 = 0,
};

pub const Volume = struct {
    thickness_texture: TextureView = .{},
    thickness_factor: f32 = 0,
    attenuation_color: [3]f32 = @splat(0),
    attenuation_distance: f32 = 0,
};

pub const Sheen = struct {
    sheen_color_texture: TextureView = .{},
    sheen_color_factor: [3]f32 = @splat(0),
    sheen_roughness_texture: TextureView = .{},
    sheen_roughness_factor: f32 = 0,
};

pub const EmissiveStrength = struct {
    emissive_strength: f32 = 0,
};

pub const Iridescence = struct {
    iridescence_factor: f32 = 0,
    iridescence_texture: TextureView = .{},
    iridescence_ior: f32 = 0,
    iridescence_thickness_min: f32 = 0,
    iridescence_thickness_max: f32 = 0,
    iridescence_thickness_texture: TextureView = .{},
};

pub const DiffuseTransmission = struct {
    diffuse_transmission_texture: TextureView = .{},
    diffuse_transmission_factor: f32 = 0,
    diffuse_transmission_color_factor: [3]f32 = @splat(0),
    diffuse_transmission_color_texture: TextureView = .{},
};

pub const Anisotropy = struct {
    anisotropy_strength: f32 = 0,
    anisotropy_rotation: f32 = 0,
    anisotropy_texture: TextureView = .{},
};

pub const Dispersion = struct {
    dispersion: f32 = 0,
};

pub const Material = struct {
    name: ?[:0]u8 = null,
    has_pbr_metallic_roughness: bool = false,
    has_pbr_specular_glossiness: bool = false,
    has_clearcoat: bool = false,
    has_transmission: bool = false,
    has_volume: bool = false,
    has_ior: bool = false,
    has_specular: bool = false,
    has_sheen: bool = false,
    has_emissive_strength: bool = false,
    has_iridescence: bool = false,
    has_diffuse_transmission: bool = false,
    has_anisotropy: bool = false,
    has_dispersion: bool = false,
    pbr_metallic_roughness: PbrMetallicRoughness = .{},
    pbr_specular_glossiness: PbrSpecularGlossiness = .{},
    clearcoat: Clearcoat = .{},
    ior: Ior = .{},
    specular: Specular = .{},
    sheen: Sheen = .{},
    transmission: Transmission = .{},
    volume: Volume = .{},
    emissive_strength: EmissiveStrength = .{},
    iridescence: Iridescence = .{},
    diffuse_transmission: DiffuseTransmission = .{},
    anisotropy: Anisotropy = .{},
    dispersion: Dispersion = .{},
    normal_texture: TextureView = .{},
    occlusion_texture: TextureView = .{},
    emissive_texture: TextureView = .{},
    emissive_factor: [3]f32 = @splat(0),
    alpha_mode: AlphaMode = .@"opaque",
    alpha_cutoff: f32 = 0,
    double_sided: bool = false,
    unlit: bool = false,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const MaterialMapping = struct {
    /// An index into `Gltf.variants`, which `validate` checks.
    variant: usize = 0,
    material: u32 = invalid_index,
    extras: Extras = .{},
};

pub const MorphTarget = struct {
    attributes: []Attribute = &.{},
};

pub const DracoMeshCompression = struct {
    /// Set when the primitive has the compression.
    buffer_view: ?u32 = null,
    attributes: []Attribute = &.{},
};

pub const MeshGpuInstancing = struct {
    attributes: []Attribute = &.{},
};

pub const Primitive = struct {
    type: PrimitiveType = .invalid,
    indices: ?u32 = null,
    material: ?u32 = null,
    attributes: []Attribute = &.{},
    targets: []MorphTarget = &.{},
    extras: Extras = .{},
    has_draco_mesh_compression: bool = false,
    draco_mesh_compression: DracoMeshCompression = .{},
    mappings: []MaterialMapping = &.{},
    extensions: []Extension = &.{},
};

pub const Mesh = struct {
    name: ?[:0]u8 = null,
    primitives: []Primitive = &.{},
    /// Null when the file has no `weights`; empty when it has an empty
    /// array, which `validate` treats differently.
    weights: ?[]f32 = null,
    /// From `extras.targetNames`; null and empty differ as for `weights`.
    target_names: ?[][:0]u8 = null,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Skin = struct {
    name: ?[:0]u8 = null,
    /// Nodes.
    joints: []u32 = &.{},
    skeleton: ?u32 = null,
    inverse_bind_matrices: ?u32 = null,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const CameraPerspective = struct {
    has_aspect_ratio: bool = false,
    aspect_ratio: f32 = 0,
    yfov: f32 = 0,
    has_zfar: bool = false,
    zfar: f32 = 0,
    znear: f32 = 0,
    extras: Extras = .{},
};

pub const CameraOrthographic = struct {
    xmag: f32 = 0,
    ymag: f32 = 0,
    zfar: f32 = 0,
    znear: f32 = 0,
    extras: Extras = .{},
};

pub const Camera = struct {
    name: ?[:0]u8 = null,
    /// cgltf's `type` and `data` in one: the projection the file gives.
    data: union(CameraType) {
        invalid,
        perspective: CameraPerspective,
        orthographic: CameraOrthographic,
    } = .invalid,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Light = struct {
    name: ?[:0]u8 = null,
    color: [3]f32 = @splat(0),
    intensity: f32 = 0,
    type: LightType = .invalid,
    range: f32 = 0,
    spot_inner_cone_angle: f32 = 0,
    spot_outer_cone_angle: f32 = 0,
    extras: Extras = .{},
};

pub const Node = struct {
    name: ?[:0]u8 = null,
    /// Set from the parent's `children`.
    parent: ?u32 = null,
    children: []u32 = &.{},
    skin: ?u32 = null,
    mesh: ?u32 = null,
    camera: ?u32 = null,
    light: ?u32 = null,
    /// Null and empty differ as for `Mesh.weights`.
    weights: ?[]f32 = null,
    has_translation: bool = false,
    has_rotation: bool = false,
    has_scale: bool = false,
    has_matrix: bool = false,
    translation: [3]f32 = @splat(0),
    rotation: [4]f32 = @splat(0),
    scale: [3]f32 = @splat(0),
    matrix: [16]f32 = @splat(0),
    extras: Extras = .{},
    has_mesh_gpu_instancing: bool = false,
    mesh_gpu_instancing: MeshGpuInstancing = .{},
    extensions: []Extension = &.{},
};

pub const Scene = struct {
    name: ?[:0]u8 = null,
    nodes: []u32 = &.{},
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const AnimationSampler = struct {
    input: u32 = invalid_index,
    output: u32 = invalid_index,
    interpolation: InterpolationType = .linear,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const AnimationChannel = struct {
    /// An index into the animation's `samplers`.
    sampler: u32 = invalid_index,
    target_node: ?u32 = null,
    target_path: AnimationPathType = .invalid,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const Animation = struct {
    name: ?[:0]u8 = null,
    samplers: []AnimationSampler = &.{},
    channels: []AnimationChannel = &.{},
    extras: Extras = .{},
    extensions: []Extension = &.{},
};

pub const MaterialVariant = struct {
    name: ?[:0]u8 = null,
    extras: Extras = .{},
};

pub const Asset = struct {
    copyright: ?[:0]u8 = null,
    generator: ?[:0]u8 = null,
    version: ?[:0]u8 = null,
    min_version: ?[:0]u8 = null,
    extras: Extras = .{},
    extensions: []Extension = &.{},
};
