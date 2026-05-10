//! Raw libgit2 C bindings. Other code in src/git/ wraps these with safer
//! Zig types; outside of src/git/ this module shouldn't be imported directly.

pub const c = @cImport({
    @cInclude("git2.h");
});
