# Issue 0001: Make status items actionable

## Status

Approved — implementation in progress.

I’m wondering if the next CurrantGit move should be making status items truly
actionable. Every meaningful thing in the surface—sections, changes, hunks,
files—could expose the actions that make sense for it, with one small idiomatic
Lua registry underneath.

That seems like the seam between the current bootstrap and the richer product:
move around a buffer-native status surface, land on an item, see what applies,
and do the useful thing without inventing a second navigation system.

The Fugitive feel should remain recognizable. The implementation should stay
modern and item-oriented. The details can be shaped after the idea earns a
yes.

Is this a good thing to pursue next? Approve it, veto it, or reshape it.
