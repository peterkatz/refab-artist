# Inflatables (experimental)

!!! warning "Experimental"
    Inflatables is still in development. It may not produce usable parts, and you should not rely on it for a real project. It is hidden until you switch it on.

## Turning it on

Open **Settings** (**Refab Artist > Settings...**, or Command-comma) and switch on **Show experimental modes**. Inflatables then appears in the Construction Technique list. Turning the switch off hides it again; a project that was saved in Inflatables keeps it until you choose another technique.

## What it tries to do

Inflatables plans flat panels and seams for an inflatable sculpture. It writes the panels as cut sheets (DXF, SVG or PDF), and the inflated shape as STL or OBJ.

A flat, sealed shape that does not stretch does not inflate into the shape you drew. It swells and pulls in, like a foil balloon, and any dent in the model tends to pop outward unless something inside holds it. Treat the output as a first-pass pattern and a way to see where the requested shape cannot be reached, not as a finished design.

## Tips

- Use it to explore. Cut a small test panel in cheap material before committing to anything.
- Because the mode is experimental, it is not covered by the cuttability gate the supported modes pass; see the [Troubleshooting](troubleshooting.md) page for the status of each mode.
