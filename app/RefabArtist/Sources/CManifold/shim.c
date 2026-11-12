/* SwiftPM requires at least one compilable source in a C target. The real
 * Manifold C API lives in the vendored static archives (Vendor/Manifold/lib);
 * this translation unit only exists to give the CManifold target a body. */
int cmanifold_shim_anchor(void) { return 0; }
