pub const c =
    @cImport({
        @cInclude("drm/drm.h");
        @cInclude("gbm.h");
    });
