LuffaHelper
===========

A small World of Warcraft addon for the Luffa trinket.

In WoW Forever, Luffa removes all Bleed, Disease, and Poison effects when you
use it while in or on water. This addon tells you when that is worth doing and
points you at the nearest water.

It shows the Luffa icon with a pulsing gold highlight, and an arrow below it
with the distance in yards, when ALL of these are true:

  - you are out of combat
  - Luffa is in your bags or equipped
  - you have a Disease or Poison with more than 45 seconds left
    (equipping a trinket starts a 30 second cooldown, so shorter ones
    would run out first)

What you see, from top to bottom:

  - The Disease or Poison that Luffa would remove, with a coloured border and
    its time left, so you can tell why the addon popped up.
  - The Luffa icon. CLICK IT to equip Luffa. Do this on your way to the water,
    so the 30 second equip cooldown runs out while you travel.
  - A gold arrow pointing at the nearest water.
  - What to do next: equip Luffa, how long until it is ready, and how far the
    water is. Once you are in water and Luffa is ready it tells you to use it.

Once Luffa is equipped the 45 second rule no longer applies, so the icon stays
up while you travel.

Luffa goes into your top trinket slot. If you also use SurfNTurf, it goes into
whichever trinket slot SurfNTurf is not using. /luffa slot changes this.

When you equip Luffa by clicking the icon, the addon remembers the trinket it
replaced and puts it back once Luffa has been used, or once the Disease or
Poison is gone. It waits until you are out of combat. If the slot was empty,
or you equipped Luffa by hand, it leaves Luffa where it is.


INSTALL
-------

1. Download LuffaHelper.zip:

    https://github.com/matthew-hakes/LuffaHelper/releases/latest/download/LuffaHelper.zip

   (The green "Code" button, then "Download ZIP", works too.)
2. Unzip it. Inside you will find this README and a folder named LuffaHelper.
3. Drag the LuffaHelper folder into your AddOns folder:

       World of Warcraft\_forever_\Interface\AddOns

   Do not rename it, and leave this README out.
4. Restart the game (or log out to character select) and make sure LuffaHelper
   is ticked in the AddOns list.


USING IT
--------

There is nothing to set up. The icon appears by itself when it is needed.

  /luffa test     Preview the icon and arrow. Hold Shift and drag the icon to
                  move it. Type it again to turn the preview off.
  /luffa slot     Choose which trinket slot Luffa is equipped into
                  (automatic, top or bottom).
  /luffa bad      Hide the spot the arrow is pointing at, and anything within
                  30 yards of it. Use this if there is no usable water there.
  /luffa reset    Bring back every spot you hid.
  /luffa mark     Save a water spot where you are standing.
  /luffa status   Show what the addon currently sees.


WHERE THE WATER COMES FROM
--------------------------

The game cannot tell an addon where water is, so the addon carries its own
list: about 30,900 spots on both continents, read from the game's map data.

  Included:   oceans and coasts, lakes, ponds, rivers, creeks, swamps and hot
              springs, plus the Stormwind canals and the water in Orgrimmar.
  Left out:   wells, fountains, moonwells, puddles, indoor pools, cave pools,
              lava, slime and tar.

The addon also remembers any place you swim, so water missing from the list
gets added as you play.


NOTES
-----

- Bleeds do not make the icon appear. The game does not label bleeds the way
  it labels Disease and Poison, so only those two are detected.
- There is no arrow inside dungeons, because the game hides your position
  there. The icon still appears.
- The arrow points in a straight line and ignores height, cliffs and walls.
- Saved spots, hidden spots and the icon position are shared by all of your
  characters.
- The water-tools folder in the repository holds the scripts that built the
  water list. You do not need them to use the addon.
