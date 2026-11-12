# Troubleshooting and known issues

This page covers common problems and the known issues in version 0.1.0. The full list is in the [release notes](https://github.com/peterkatz/refab-artist/blob/main/docs/releases/0.1.0.md).

## Mode status

| Mode | Status |
|---|---|
| Stacked | Supported |
| Interlocked | Supported |
| Radial | Supported |
| Curve | Supported with known limits |
| Folded | Supported with known limits |
| 3D Slices | Supported |
| Structures | Supported |
| Partition | Supported with known limits |
| MotherMold | Supported with known limits |
| Make Watertight, Hollow, Thicken | Supported |
| Inflatables | Experimental |

"Supported" means the mode passes the checks listed in the release notes. None of them has had a physical cut test yet; cut a small test piece in your own material first ([Cutting and fit](cutting-and-fit.md)).

## Common problems

**The model is tiny or huge.** The file's units are guessed. Open the **Object** tab and set the unit or type the real size under **Object Size**.

**Nothing happens after I pick a technique.** Settings changes do not recompute anything. Press **Slice** (or **Generate**).

**A control is greyed out.** Another setting overrides it, and a short note under it says which. For example, Slot Offset is greyed out while Notch width is on.

**The parts don't fit together.** Adjust **Slot Offset** and cut again; see [Cutting and fit](cutting-and-fit.md).

**Fewer parts than I asked for.** Curve, Radial and Interlocked cut fewer ribs or rings when that many would stand closer than the stock thickness, or leave too little material between slots. A note under the control says so.

**A part is red or blue on the cut sheet.** Red means a part that is difficult or impossible to build; blue means a piece that would fall off and must be glued in place. Look at the **Issues** tab.

**The model has holes or flipped faces.** Use [Make Watertight](model-repair.md) first.

**The Inflatables mode is missing.** It is experimental. Turn on **Show experimental modes** in Settings.

## Known issues in 0.1.0

### Cut-sheet modes

- **Curve, first axis Y, 5 mm stock.** On some organic models a few parts are marked (blue on the cut sheet) to be glued in place instead of being held by joints. Another first axis, fewer curve slices or thinner stock join them.
- **Curve, ribs moved to join parts.** A first-axis rib moved off its even spacing can leave a small lip near flat faces.
- **Slice Direction and STL / OBJ.** With a tilted Slice Direction, the STL and OBJ files are written in the tilted frame: the whole assembly comes out turned by the tilt. The 3D view and the cut sheets are not affected.
- **Radial fin count.** Asking for 8 fins gives 10.
- **Interlocked and the joint check.** The project's checks confirm slot widths and cuttability on Interlocked but cannot check that every pair of slots mates.
- **Interlocked, thick stock on a small model.** If the stock is as thick as the slice spacing, the slots merge and each part loses its slotted half. Nothing warns about it; set **Distribute count** to fix it.
- **Radial.** Ring pieces that no fin reaches are left out, and the notes name them. Pieces that meet the other family only where a line crosses the model more than once are marked to be glued, not locked.
- **Curve.** Where the curve bends sharply, the curve ribs stop short of the concave side. A few ribs have thin webs, and notes name them.
- **Folded.** It assumes the stock bends at the fold lines. On curved models most edges are left plain to glue or tape. Assembly step numbers count panels, while the cut sheet has one part per net, so they differ from the sheet labels.
- **Assembly order** is not checked for Curve and Folded.

### Partition

- **Split by Undercuts on scanned models is not checked yet.** On an organic scan, check each piece in the 3D view before you mould it. Fit Printer is not affected.

### MotherMold

- **Four-part reusable silicone mold on some models.** On a low-poly head test model the build stops while placing the liner registration buttons. No mold package is written.
- **Four-part mold of a hand scan with X and Z planes through its centre.** Two of the quarter shells come out in two pieces each, and the planner refuses a mold part in two pieces. The X/Y and Y/Z plane pairs on the same scan work.
- **Prepared master of an already healed hand scan.** The prepared master can be refused.
- **Pour funnel on a small mold.** The default 12 mm sealed pour funnel does not fit on one part of a 50 mm cube parted through its centre; a 10 mm one does. Choose a smaller spout on small molds.

### Other

- Physical cut tests are not done.
- Inflatables is experimental.
- The app has been run on macOS 26 only.
- At small sizes, such as Finder's list view, macOS 26 shows the app icon on a light-grey backdrop.
- No Intel, Windows or Linux build, no automatic update, no Homebrew cask and no Mac App Store release.

## Getting help

Open an issue on the [GitHub repository](https://github.com/peterkatz/refab-artist/issues). Say which mode you were in, what you expected and what happened, and attach the model if you can share it.
