pids=$(pidof zls)
pidsarr=($pids)
pid=${pidsarr[0]}
echo "zls pids $pids killing first pid $pid"
kill $pid
