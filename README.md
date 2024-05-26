![pfUI QuickCast](https://latex.codecogs.com/svg.latex?%5Cfn_jvn%20%5Chuge%20%5Ctextup%7B%5CLARGE%5Ctextbf%7B%7B%5Ccolor%7BCyan%7Dpf%7D%7B%5Ccolor%7BOrange%7DUI%7D%5C%20%5Chuge%7B%5Ccolor%7BEmerald%7DQuickCast%7D%7D%7D)

The '/pfquickcast@*' family of commands are more performant flavours of the original '/pfcast' command from pfUI.mouseover module.

These commands work only in Vanilla Warcraft 1.12 and its family of derivatives.

# 🚧 Work In Progress - Coming Soon 🚧

## ❓ Why pfUI-QuickCast?

- **Performance**: The '/pfquickcast@heal' command is leaner and more performant than the original '/pfcast' command from pfUI.mouseover module.

  <br/>The original implementation of '/pfcast' command constantly invokes 'loadstring()' under the hood to evaluate the spell name string passed to it.
  Even though this works fine for most cases, it's just too much churning for too little gain when used in macros that are executed frequently
  such as healing macros that healers spam in a raid context:<br/><br/>

  'Flash of Light'<br/>
  Down-ranked 'Healing Touch'<br/>
  'Rejuvenation'<br/>

  <br/>One could argue that /pfcast could be refactored further so that 'loadstring()' could be wrapped and made smarter with some sort of caching mechanism
  for the most commonly used LUA scripts passed to it, but that's just feels as flogging an ailing horse.<br/><br/>

- **Intention**: The '/pfquickcast@heal' command and only that is interceptable by healing auto-ranking addons for optimum performance.<br/><br/>

- **Targeting**: The implementation of the '/pfquickcast@heal' is such that it only casts spells on **friendly** targets.<br/>

  <br/>This is important for spells like 'Holy Shock' that can be used on both friendly and hostile targets. The '/pfcast' command on the contrary
  is not aware of the target type and will cast 'Holy Shock' on the currently selected target if it's hostile prioritizing it over the friendly
  target that you intend to heal with mouse-over. :(

  <br/>If someone wants to force '/pfcast' to cast 'Holy Shock' on the friendly mouse-over target (even if a hostile target is selected), they would have to
  resort to writing a LUA wrapper-script. This sort of "LUA heartburn" is no longer necessary with the '/pfquickcast@heal' command. 

  <br/>This is just one of the many issues plaguing the original '/pfcast' command that '/pfquickcast@heal' fixes right ouf of the box.


- **Simplicity of Integration with Heal-Auto Ranking Addons**: The '/pfquickcast@heal' command works seamlessly and transparently with heal-auto-ranking addons that support it.<br/><br/>

  Unless you want to do something very advanced using your own custom LUA macro-script, there's absolutely no need to write counter-intuitive LUA scripts.<br/><br/>

  This is how simply '/pfcast' is meant to be used with heal auto-ranking addons:<br/>

  ```lua
   /pfquickcast@heal Holy Light   -- the heal auto-ranking addon will intercept this call and cast the most appropriate rank of 'Holy Light' based on the target's health
  ```

  With the '/pfquickcast@heal' approach if you decide to switch over to another heal-auto-ranking addon you don't have to edit any of your macros - just switch over to your new heal-auto-ranking
  addon and everything will work transparently (provided of course that your new heal-auto-ranking addon supports /pfquickcast@heal indeed).<br/><br/>

  Just for the sake of comparison, here's how '/pfcast' is meant to be used with heal auto-ranking addons:<br/>

  ```lua
   /pfcast YourPreferredHealAutoRankingAddon:Cast("Holy Light")
  ```
  
  Apart from an alienating syntax, this approach means that if you decide to switch over to another heal-auto-ranking addon **you're forced to manually edit all your macros** to reflect the new
  heal-auto-ranking addon's API.<br/><br/>

## 🕮  Basic Usage:

- `/pfquickcast@heal <healing_spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HEAL("<healing_spell_name>")` )

  <br/>Casts healing spells on **friendly** targets in the following order of priority:

  <br/>- If the mouse hovers over a friendly unit-frame (or toon in the game world), then that friendly unit will be healed. 

  <br/>- Otherwise the healing spell will be cast on the currently selected friendly target (if any.)

  <br/>- If no suitable target is found in the above cases, the spell will **not** be cast even if you have AutoSelfCast=true in your CVars. This behaviour is by design
  the exact opposite to what '/pfcast' does, so that you won't accidentally heal yourself when you meant to heal someone else thus wasting both mana and precious time in a raid context.
  
  <br/>- Note that you can in fact specify multiple healing spells in a single macro. If the first spell is not castable due to cooldown or because you haven't picked it in your talent
  tree, the next one will be tried to be cast and so on:
  
  <br/>A typical use-case of this feature is with the Paladin's 'Holy Shock' talent:

  ```lua
  /pfquickcast@heal Holy Shock, Flash of Light --                         if you have the 'Holy Shock' talent in your talent build and its off
  
  -- alternative syntax
  /script SlashCmdList.PFQUICKCAST_HEAL("Holy Shock, Flash of Light") --  cooldown, it will be cast, otherwise 'Flash of Light' will be cast
  ```

  <br/>Note: The above feature can't be used as-is to fall back to lower ranks of the same spell if the first spell in the list is not castable due to low mana. If you want to achieve this
  one way to do it is this one:
 
  ```lua
  /pfquickcast@heal Holy Shock, Flash of Light --                         if you have enough mana
  /pfquickcast@heal Holy Shock(Rank 1), Flash of Light --                 if you've run low on mana it fallback to one of these heals
  /pfquickcast@heal Holy Shock(Rank 1), Flash of Light(Rank 3) --         if you've run even lower on mana it fallback to one of these heals
  
  -- alternative syntax
  /script SlashCmdList.PFQUICKCAST_HEAL("Holy Shock, Flash of Light"); SlashCmdList.PFQUICKCAST_HEAL("Holy Shock(Rank 1), Flash of Light"); SlashCmdList.PFQUICKCAST_HEAL("Holy Shock(Rank 1), Flash of Light(Rank 3)")
  ```

  <br/>- The healing spell that did get cast by the LUA method will be returned - if no spell was castable then 'nil' will be returned.

  <br/>Note: Heals cast with this flavour do get intercepted by healing auto-ranking addons.<br/><br/>


- `/pfquickcast@healself <healing_spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HEAL_SELF("<healing_spell_name>")` )

  <br/>Casts healing spells on your **character** no matter what.

  <br/>Note: Heals cast with this flavour do get intercepted by healing auto-ranking addons.<br/><br/>


- `/pfquickcast@healtote <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HEAL_TOTE("<spell_name>")` )

  <br/>Casts heals to the target-of-the-enemy (tote). This will work **only** if you're mouse-hovering over a **hostile** unit in which case it will find the friendly target that it's attacking
  to heal it.

  <br/>- Note that this flavour will automatically **change** your current target to the hostile unit you're mouse-hovering over. Use with caution.

  <br/>- This flavour is meant to be used mainly when healing boss-fights that necessitate tank swaps, in which case you want your heals to land automatically on the tank that the boss is currently
  attacking at any given moment.<br/>


- `/pfquickcast@self <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_SELF("<spell_name>")` )

  <br/>Casts spells on your **character** no matter what.

  <br/>Note that (normally) this flavour is not interceptable by heal-auto-ranking addons and should be used for spells that are meant to be cast
  exactly as you specify them on your character.<br/>


- `/pfquickcast@friends <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_FRIENDS("<spell_name>")` )

  <br/>Casts spells on **friendly** targets p.e. on pfUI frames via mouse-hover.

  <br/>Use this flavour for **friendly** spells or generic spells that can be used on both friendly and hostile targets (p.e. Paladin's Holy Shock).

  <br/>Note that (normally) this flavour is not interceptable by heal-auto-ranking addons and should be used for spells that are meant to be cast
  exactly as you specify them on friendly targets.<br/>


- `/pfquickcast@hostiles <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HOSTILES("<spell_name>")` )

  <br/>Casts spells on **hostile / neutral** targets p.e. via mouse-hover directly on the NPCs or in pfUI unit-frames.

  <br/>- You can in fact specify multiple spells in a single macro. If the first spell is not castable (p.e. out of range, on CD, etc.) the next one will be attempted to be cast and so on.

  <br/>Use this flavour for **offensive** spells or generic spells that can be used on both friendly and hostile targets (p.e. Paladin's Holy Shock).<br/>


- `/pfquickcast@any <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_ANY("<spell_name>")` )

  <br/>Casts spells to any target (friendly, neutral or hostile) p.e. on pfUI frames via mouse-hover.<br/>



## 🏗️  Installation

1. Download the **[latest version](https://github.com/dsidirop/pfUI-quickcast/archive/refs/heads/main.zip)**
2. Unpack the .zip file
3. Rename the folder "pfUI-quickcast-main" → "pfUI-quickcast"
4. Copy "pfUI-quickcast" into

       <Your Warcraft Directory>\Interface\AddOns

5. Restart World of Warcraft

## 🟡  Credits

- [Shagu](https://github.com/shagu) author of [pfUI](https://github.com/shagu/pfUI) 
