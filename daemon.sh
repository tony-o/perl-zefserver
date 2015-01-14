#!/bin/sh

if [ -z "$1" ]; then
  echo "Usage: $0 [start|reload|stop|status]";
  exit 0;
fi

if [ "$1" = "status" ]; then 
  if [ -f "script/hypnotoad.pid" ]; then
    echo 'App is running';
  else
    echo 'App is stopped';
  fi
  exit 0;
fi

if [ "$1" = "start" ] || [ "$1" = "reload" ]; then
  hypnotoad script/app;
  exit 0;
fi

if [ "$1" = "stop" ]; then
  hypnotoad -s script/app;
  exit 0;
fi
