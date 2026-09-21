# Frozen C reference

`c/` is byte-for-byte the previous Strafe Next 0.1 `src/core` directory from the
supplied `strafe-next.zip`. The source hashes are recorded in the port validation
summary and package manifest. It is test data/reference implementation only.

The app links `librheo_ffi.a`; no file from this directory is part of its build.
The differential suite compiles this C copy with `ref_sn_*` symbol prefixes and
compares it against Rust. The benchmark builds separate C-reference and Rust-FFI
executables with the same caller. Do not edit this oracle merely to make a Rust
regression pass; document any intended semantic difference instead.

The delivery-environment self-check ran the C reference against a second prefixed
copy of C to verify the harness itself. That run says nothing about Rust equivalence.
