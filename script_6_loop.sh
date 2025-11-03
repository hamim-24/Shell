#!/bin/zsh

var=1

while [ $var -le 10 ] 
do
    echo $var
    var=$(( var + 1 ))
    sleep 0.5
done

