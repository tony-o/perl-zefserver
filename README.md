#__RESTful API__

##/login
###Expects
>_Content-Type: application/json_
```json
{
  "username": "<username>",
  "password": "<password>"
}
```
###Returns
####Success
```json
{
  "success": 1,
  "newkey" : "<user token>" 
}
```
####Failure
```json
{
  "failure": 1,
  "reason" : "<some reason>"
}
```

##/register
See _/login_

##/push
###Expects
>_Content-Type: application/json_
```json
{
  "key":     "<a valid user token>",
  "majorvs": "1", /* necessary ONLY to inc major version */
  "minorvs": "1", /* necessary ONLY to inc minor version */
  "meta":    {
    "name"      : "<package's name>",
    "repository": "<a git repository>"
  }
}
```

###Returns
####Success
```json
{
  "latestcommit": "<commit ID that the version corresponds to>",
  "version"     : "<version # as far as ZEF is concerned>"
}
```
####Failure
```json
error
```

##/search
###Expects
>_Content-Type: application/json_
```json
{
  "query": "<search term>",
  "page" : #   /* This is an optional argument */
}
```

####Success
```json
[
  { 
    "package"  : "<package name>",
    "author"   : "<author>",
    "version"  : "<ZEF version>",
    "submitted": "<date/time submitted>"
  },
  { 
    "package": "<package name>",
    "author" : "<author>",
    "version": "<ZEF version>"
  }
]
```
####Failure
```json
[ ]
```

##/download
###Expects
>_Content-Type: application/json_
```json
{
  "name":    "<package name>",
  "author":  "<package author>",   /* This is an optional argument */
  "version": "<package version>",   /* This is an optional argument */
}
```

####Success
```json
[
  { 
    "repo":    "<package repo>",
    "commit" : "<commit id to download to>",
    "version": "<ZEF version>",
    "author":  "<package author>"
  }
]
```
####Failure
```json
[ ]
```
