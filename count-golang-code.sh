find . -name "*.go" |grep -v vendor|xargs cat|grep -v "//"|grep -v "^$"|wc -l
