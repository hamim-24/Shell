#!/bin/zsh

var=10

while [ $var -ge 0 ] 
do
    echo "$var"
    var=$(( var - 1 ))
done

