tell application "iTerm"
    tell current window
        create tab with default profile
    end tell
    tell current session of current window
        set background image to "/tmp/rdimg.jpg"
    end tell
end tell
do shell script "/usr/local/bin/wget -O /tmp/tmprdimg.jpg https://picsum.photos/1400/800?random && cp /tmp/tmprdimg.jpg /tmp/rdimg.jpg"
-- Image source substitutions:
-- https://picsum.photos/1400/800?random
-- https://source.unsplash.com/random/1400x800
-- https://source.unsplash.com/featured/1400x800?girl
-- http://placeimg.com/1400/800/any
