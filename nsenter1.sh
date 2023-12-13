docker run -it --privileged --pid=host debian nsenter -t 1 -m -u -n -i sh

# docker run -it --rm --privileged --pid=host justincormack/nsenter1
