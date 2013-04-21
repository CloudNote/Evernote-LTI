Evernote-LTI
============

An LTI Provider application to integrate the Evernote service into an LMS.


Installation
------------

See the [Gemfile](http://github.com/Dritz/Evernote-LTI/blob/master/Gemfile) for the dependencies required to run the application.
The project uses OAuth to authorize LMS users for Evernote. It is written primarily in [Sinatra](http://www.sinatrarb.com/),
authentication data is stored in a [Postgres](http://www.postgresql.org/) database, and the project is hosted by [Heroku](https://www.heroku.com/). 

To access Evernote for this project, a developer API key is required and can be requested [here](http://dev.evernote.com/documentation/cloud/).

Usage
-----

The application is intended to conform to LTI standards. Please see the [LTI documentation](http://www.imsglobal.org/lti/index.html) for more. 