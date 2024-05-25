![pfUI QuickCast](https://latex.codecogs.com/svg.latex?%5Cfn_jvn%20%5Chuge%20%5Ctextup%7B%5CLARGE%5Ctextbf%7B%7B%5Ccolor%7BCyan%7Dpf%7D%7B%5Ccolor%7BOrange%7DUI%7D%5C%20%5Chuge%7B%5Ccolor%7BEmerald%7DQuickCast%7D%7D%7D)

The '/pfquickcast.*' family of commands are more performant flavours of the original '/pfcast' command from pfUI.mouseover module.

These commands work only in Vanilla Warcraft 1.12 and its family of derivatives.

# 🚧 Work In Progress - Coming Soon 🚧

## ❓ Why pfUI-QuickCast?

- **Performance**: The '/pfquickcast.heal' command is leaner and more performant than the original '/pfcast' command from pfUI.mouseover module.

  <br/>The original implementation of '/pfcast' command constantly invokes 'loadstring()' under the hood to evaluate the spell name string passed to it.
  Even though this works fine for most cases, it's just too much churning for too little gain when used in macros that are executed frequently
  such as healing macros that healers spam in a raid context:<br/><br/>

  'Flash of Light'<br/>
  Down-ranked 'Healing Touch'<br/>
  'Rejuvenation'<br/>

  <br/>One could argue that /pfcast could be refactored further so that 'loadstring()' could be wrapped and made smarter with some sort of caching mechanism
  for the most commonly used LUA scripts passed to it, but that's just feels as flogging an ailing horse.<br/><br/>

- **Intention**: The '/pfquickcast.heal' command and only that is interceptable by healing auto-ranking addons for optimum performance.<br/><br/>

- **Targeting**: The implementation of the '/pfquickcast.heal' is such that it only casts spells on **friendly** targets.<br/>

  <br/>This is important for spells like 'Holy Shock' that can be used on both friendly and hostile targets. The '/pfcast' command on the contrary
  is not aware of the target type and will cast 'Holy Shock' on the currently selected target if it's hostile prioritizing it over the friendly
  target that you intend to heal with mouse-over. :(

  <br/>If someone wants to force '/pfcast' to cast 'Holy Shock' on the friendly mouse-over target (even if a hostile target is selected), they would have to
  resort to writing a LUA wrapper-script. None of this is needed with the '/pfquickcast.heal' command. 

  <br/>This is a very common issue with the original '/pfcast' command that '/pfquickcast.heal' fixes right ouf of the box.


- **Simplicity of Integration with Heal-Auto Ranking Addons**: The '/pfquickcast.heal' command works seamlessly and transparently with heal-auto-ranking addons that support it.<br/><br/>

  Unless you want to do something very advanced using your own custom LUA macro-script, there's absolutely no need to write counter-intuitive LUA scripts.<br/><br/>

  This is how simply '/pfcast' is meant to be used with heal auto-ranking addons:<br/>

  ```lua
   /pfquickcast.heal Holy Light   -- the heal auto-ranking addon will intercept this call and cast the most appropriate rank of 'Holy Light' based on the target's health
  ```

  With the '/pfquickcast.heal' approach if you decide to switch over to another heal-auto-ranking addon you don't have to edit any of your macros - just switch over to your new heal-auto-ranking
  addon and everything will work transparently.<br/><br/>

  And for the sake of comparison, here's how '/pfcast' is meant to be used with heal auto-ranking addons:<br/>

  ```lua
   /pfcast YourPreferredHealAutoRankingAddon:Cast("Holy Light")
  ```
  
  Apart from an alienating syntax, this approach means that if you decide to switch over to another heal-auto-ranking addon you have to manually edit all your macros to reflect the new
  heal-auto-ranking addon's API.<br/><br/>

## 🕮  Basic Usage:

- `/pfquickcast:heal <healing_spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HEAL("<healing_spell_name>")` )

  <br/>Casts healing spells on **friendly** targets p.e. on pfUI frames via mouse-hover.
 
  <br/>If an enemy unit is mouse-hovered, the spell will be cast on its target (if it's friendly). 

  <br/>Heals cast with this flavour do get intercepted by healing auto-ranking addons.<br/><br/>


- `/pfquickcast:selfheal <healing_spell_name>` ( `/script SlashCmdList.PFQUICKCAST_SELFHEAL("<healing_spell_name>")` )

  <br/>Casts healing spells on your **character** no matter what.

  <br/>Heals cast with this flavour do get intercepted by healing auto-ranking addons.<br/><br/>


- `/pfquickcast:self <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_SELF("<spell_name>")` )

  <br/>Casts spells on your **character** no matter what.

  <br/>Note that (normally) this flavour is not interceptable by heal-auto-ranking addons and should be used for spells that are meant to be cast
  exactly as you specify them on your character.<br/>


- `/pfquickcast:friendlies <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_FRIENDLIES("<spell_name>")` )

  <br/>Casts spells on **friendly** targets p.e. on pfUI frames via mouse-hover.

  <br/>Use this flavour for **friendly** spells or generic spells that can be used on both friendly and hostile targets (p.e. Paladin's Holy Shock).

  <br/>Note that (normally) this flavour is not interceptable by heal-auto-ranking addons and should be used for spells that are meant to be cast
  exactly as you specify them on friendly targets.<br/>


- `/pfquickcast:hostiles <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_HOSTILES("<spell_name>")` )

  <br/>Casts spells on **hostile/neutral** targets p.e. via mouse-hover directly on the NPCs or in pfUI unit-frames.
  
  <br/>Use this flavour for **offensive** spells or generic spells that can be used on both friendly and hostile targets (p.e. Paladin's Holy Shock).<br/>


- `/pfquickcast:any <spell_name>` ( `/script SlashCmdList.PFQUICKCAST_ANY("<spell_name>")` )

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
