# Vulkan Validation Layers

This document describes the Debug-only Vulkan validation setup for the
`vulkan-zig` renderer.

## Build option

Expose a compile-time flag from `build.zig`:

```zig
const mode = b.option(
    std.builtin.OptimizeMode,
    "mode",
    "Build mode",
) orelse .Debug;

const options = b.addOptions();
options.addOption(bool, "enable_validation", mode == .Debug);

const exe = b.addExecutable(.{
    .name = "zig_zine",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = mode,
    }),
});
exe.root_module.addOptions("build_options", options);
```

Build Debug or Release explicitly:

```sh
zig build -Dmode=Debug
zig build -Dmode=ReleaseFast
```

`enable_validation` is true only for Debug builds.

## Vulkan dispatch entries

The instance dispatch wrapper must load the debug messenger functions:

```zig
const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
    // Other instance functions used by the renderer...
});
```

## Debug callback

The callback receives validation messages and prints the message text:

```zig
fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = severity;
    _ = message_types;
    _ = user_data;

    if (callback_data) |data| {
        if (data.p_message) |message| {
            std.debug.print("Vulkan validation: {s}\n", .{message});
        }
    }

    return vk.FALSE;
}

fn debugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{
            .verbose_bit_ext = true,
            .info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = debugCallback,
    };
}
```

## Instance creation

When validation is enabled, request both the validation layer and the
`VK_EXT_debug_utils` instance extension:

```zig
const validation_layer_name: [*:0]const u8 =
    "VK_LAYER_KHRONOS_validation";

var extension_names =
    try std.ArrayList([*:0]const u8).initCapacity(allocator, ext_count + 1);
defer extension_names.deinit();

for (0..ext_count) |i| {
    try extension_names.append(sdl_extensions[i]);
}

var debug_create_info: ?vk.DebugUtilsMessengerCreateInfoEXT = null;
const validation_layers = [_][*:0]const u8{validation_layer_name};

if (build_options.enable_validation) {
    try extension_names.append(vk.extensions.ext_debug_utils.name);
    debug_create_info = debugMessengerCreateInfo();
}

const instance = try vkb.createInstance(&.{
    .p_next = if (debug_create_info) |*info| info else null,
    .p_application_info = &app_info,
    .enabled_extension_count = @intCast(extension_names.items.len),
    .pp_enabled_extension_names = extension_names.items.ptr,
    .enabled_layer_count = if (build_options.enable_validation)
        validation_layers.len
    else
        0,
    .pp_enabled_layer_names = if (build_options.enable_validation)
        &validation_layers
    else
        null,
}, null);
```

Passing the debug messenger create info through `p_next` allows validation
messages to be reported during instance creation itself.

## Messenger lifecycle

After loading the instance dispatch table, create the messenger in Debug mode:

```zig
const debug_messenger = if (build_options.enable_validation)
    try vki.createDebugUtilsMessengerEXT(
        instance,
        &debugMessengerCreateInfo(),
        null,
    )
else
    null;
```

Store the result as an optional field:

```zig
debug_messenger: ?vk.DebugUtilsMessengerEXT,
```

Destroy it before destroying the Vulkan instance:

```zig
if (self.debug_messenger) |messenger| {
    self.vki.destroyDebugUtilsMessengerEXT(
        self.instance,
        messenger,
        null,
    );
}

self.vki.destroyInstance(self.instance, null);
```

Use `errdefer` after instance creation so partially initialized Vulkan state
also destroys the messenger and instance correctly.

## Runtime requirement

The Vulkan SDK must provide the layer named:

```text
VK_LAYER_KHRONOS_validation
```

If the layer is not installed, Debug instance creation fails. A production
renderer should enumerate available instance layers first and enable validation
only when the requested layer is present.
