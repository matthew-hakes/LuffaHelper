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

Once Luffa is equipped the 45 second rule no longer applies, so the icon stays
up while you travel. When you are in water the arrow is replaced by a message
telling you to use Luffa.


INSTALL
-------

1. On the GitHub page click the green "Code" button, then "Download ZIP".
2. Unzip it.
3. Copy the LuffaHelper-main folder (the one with LuffaHelper.lua directly
   inside it) into your AddOns folder:

       World of Warcraft\_forever_\Interface\AddOns

   You do not need to rename it. The addon loads from a folder named either
   LuffaHelper-main or LuffaHelper. Only keep one of them, not both.
4. Restart the game (or log out to character select) and make sure LuffaHelper
   is ticked in the AddOns list.

There is also a ready-made LuffaHelper.zip (folder already named LuffaHelper)
here:

    https://github.com/matthew-hakes/LuffaHelper/releases/latest/download/LuffaHelper.zip


USING IT
--------

There is nothing to set up. The icon appears by itself when it is needed.

  /luffa test     Preview the icon and arrow. Hold Shift and drag the icon to
                  move it. Type it again to turn the preview off.
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
