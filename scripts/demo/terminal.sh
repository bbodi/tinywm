#!/bin/bash
# Runs in the demo's terminal window: types a command and shows a sample tinywm config.
# The prompt is fixed, so no user name or path shows in the recording.
printf '\033]0;tinywm config\007'
clear
P=$'\033[1;35m❯\033[0m '
printf '%s' "$P"
sleep 0.6
cmd="cat ~/.config/tinywm/config"
for ((i = 0; i < ${#cmd}; i++)); do printf '%s' "${cmd:i:1}"; sleep 0.04; done
printf '\n'
sleep 0.3
k=$'\033[38;5;141m' v=$'\033[38;5;223m' g=$'\033[38;5;245m' r=$'\033[0m'
cat <<CONF
${g}# Reloads the moment you save it.${r}
${k}default-width${r} = ${v}0.5${r}            ${g}# new windows take half the screen${r}
${k}gap${r}           = ${v}12${r}

${k}float${r}    = ${v}com.apple.calculator, System Settings${r}
${k}no-focus${r} = ${v}Slack${r}                ${g}# never steals focus${r}
${k}open-on${r}  = ${v}Mail -> workspace 2${r}

${k}send${r} space = ${v}cmd+space${r}          ${g}# meta+Space opens your launcher${r}
${k}run${r} shift+return = ${v}open -na Ghostty${r}
CONF
printf '\n%s' "$P"
exec sleep 3600
