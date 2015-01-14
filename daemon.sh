#!/bin/sh
BASEDIR=`dirname $0`

if [ -z "$1" ]; then
  echo "Usage: $0 [start|reload|stop|status|restart]";
  exit 0;
fi

if [ "$1" = "status" ]; then 
  if [ -f "$BASEDIR/script/hypnotoad.pid" ]; then
    echo 'App is running';
  else
    echo 'App is stopped';
  fi
  exit 0;
fi

if [ "$1" = "start" ] || [ "$1" = "reload" ]; then
  hypnotoad "$BASEDIR/script/app";
  exit 0;
fi

if [ "$1" = "restart" ]; then
  if [ -f "$BASEDIR/script/hypnotoad.pid" ]; then
    hypnotoad -s "$BASEDIR/script/app";
    sleep 1;
  fi
  hypnotoad "$BASEDIR/script/app";
  exit 0;
fi

if [ "$1" = "stop" ]; then
  hypnotoad -s "$BASEDIR/script/app";
  exit 0;
fi

echo "Command $1 not recognized";
exit 1;
