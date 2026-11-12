#ifndef C_MANIFOLD_SHIM_H
#define C_MANIFOLD_SHIM_H

/* Umbrella header for the vendored Manifold plain-C API (manifoldc).
 * This exposes ONLY the C surface — no C++ — so Swift can import it in
 * DEFAULT mode (no C++ interop). The static archives are linked via
 * Package.swift linkerSettings (Vendor/Manifold/lib). */
#include "manifold/manifoldc.h"

#endif /* C_MANIFOLD_SHIM_H */
