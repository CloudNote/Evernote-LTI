require 'sinatra'
require 'ims/lti'
require 'pg'
require 'yaml'
require 'pp'
require 'dalli'
# Must include the oauth proxy object
require 'oauth/request_proxy/rack_request'
# Includes for evernote
require 'oauth'
require 'oauth/consumer'
require 'evernote-thrift'
#require 'evernote-oauth'

# Enable session storing in cookies
enable :sessions
# Disable Rack frame embedding protection
set :protection, :except => :frame_options
# Enable memcached usage through Dalli
set :cache, Dalli::Client.new(ENV['MEMCACHE_SERVERS'], 
                              :username => ENV['MEMCACHE_USERNAME'], 
                              :password => ENV['MEMCACHE_PASSWORD'],   
                              :expires_in => 300) 

get '/' do
  erb :index
end

# The consumer keys/secrets
# TODO: figure out what to do with these
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

# Load database and evernote API info
conninfo = YAML.load_file('settings.yml')

# Connect to database
dbconn = PG.connect(conninfo["db"]["host"],
                    conninfo["db"]["port"],
                    nil, # options
                    nil, # tty
                    conninfo["db"]["dbname"],
                    conninfo["db"]["user"],
                    conninfo["db"]["password"])
                    
# Evernote server information
# Replace EVERNOTE_SERVER with https://www.evernote.com
# to use production servers
EVERNOTE_SERVER = "https://sandbox.evernote.com"
REQUEST_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
ACCESS_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
AUTHORIZATION_URL = "#{EVERNOTE_SERVER}/OAuth.action"
NOTESTORE_URL_BASE = "#{EVERNOTE_SERVER}/edam/note/"

# Halts execution to show an error page
def show_error(message)
  @message = message
  erb :error
end

# Authorizes the user during any LTI launch
def authorize!
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      @tp = IMS::LTI::ToolProvider.new(nil, nil, params)
      @tp.lti_msg = "Your consumer didn't use a recognized key."
      @tp.lti_errorlog = "You did it wrong!"
      return show_error "Consumer key wasn't recognized"
    end
  else
    return show_error "No consumer key"
  end

  if !@tp.valid_request?(request)
    return show_error "The OAuth signature was invalid"
  end

  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    return show_error "Your request is too old."
  end

  if was_nonce_used?(@tp.request_oauth_nonce)
    return show_error "Why are you reusing the nonce?"
  else
    cache_nonce(@tp.request_oauth_nonce, @tp.request_oauth_timestamp.to_i)
  end

  # Save the launch parameters for use in later request
  session['launch_params'] = @tp.to_params

  @username = @tp.username("Anonymous")
end

# The url for launching the tool
# It will verify the OAuth signature
# TODO: evalute if we need grade writeback
post '/lti_tool' do
  authorize!

  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # Normal tool launch without grade write-back
    @tp.lti_msg = "Sorry that tool was so boring"
    erb :boring_tool
  end
end

# Generate the page when launching from an editor button
post '/lti_tool_embed' do
  authorize!
  
  # TODO: build the page properly
  erb :embed
end

# Post the assessment results
# TODO: evaluate if we need this
post '/assessment' do
  if session['launch_params']
    key = session['launch_params']['oauth_consumer_key']
  else
    return show_error "The tool never launched"
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], session['launch_params'])

  if !@tp.outcome_service?
    return show_error "This tool wasn't lunched as an outcome service"
  end

  # Post the given score to the TC
  res = @tp.post_replace_result!(params['score'])

  if res.success?
    @score = params['score']
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :assessment_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the score."
    show_error "Your score was not recorded: #{res.description}"
  end
end

# Generates the LTI tool configuration XML
get '/tool_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/lti_tool"
  tc = IMS::LTI::ToolConfig.new(:title => "Evernote LTI", :launch_url => url)
  tc.description = "Evernote integration for the Canvas LMS"
  tc.icon = "http://evernote-lti.herokuapp.com/favicon.ico"
  
  # Extended params for Canvas LTI editor buttons
  editor_params = { "tool_id" => "evernote",
                    "privacy_level" => "anonymous",
                    "editor_button" => 
                    {   "url" => "http://evernote-lti.herokuapp.com/lti_tool_embed",
                        "icon_url" => "http://evernote-lti.herokuapp.com/favicon.ico",
                        "text" => "Evernote",
                        "selection_width" => 690,
                        "selection_height" => 530,
                        "enabled" => true,  },
                    "resource_selection" =>
                    {   "url" => "http://evernote-lti.herokuapp.com/lti_tool_embed",
                        "icon_url" => "http://evernote-lti.herokuapp.com/favicon.ico",
                        "text" => "Evernote",
                        "selection_width" => 690,
                        "selection_height" => 530,
                        "enabled" => true,  } }
  
  tc.set_ext_params("canvas.instructure.com", editor_params)

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

# Checks if nonce was used recently
def was_nonce_used?(nonce)
    timestamp = settings.cache.get(nonce)

    if(!(timestamp.nil?) && (timestamp.to_i < 300) )
        return true # nonce recently used
    else
        return false
    end
end

# Caches the nonce
def cache_nonce(nonce, timestamp)
    settings.cache.set(nonce, timestamp) 
end

# Begin Evernote authorization test

##
# Reset the session
##
get '/reset' do
  session.clear
  erb :authorize
end

##
# Get temporary credentials and redirect the user to Evernote for authorization
##
get '/authorize' do
  authorize!
  callback_url = request.url.chomp("authorize").concat("callback")

  begin
    consumer = OAuth::Consumer.new(conninfo["evernote"]["key"], conninfo["evernote"]["secret"],{
      :site => EVERNOTE_SERVER,
      :request_token_path => "/oauth",
      :access_token_path => "/oauth",
      :authorize_path => "/OAuth.action"})
      session[:request_token] = consumer.get_request_token(:oauth_callback => callback_url)
      redirect session[:request_token].authorize_url
  rescue => e
    @last_error = "Error obtaining temporary credentials: #{e.message}"
    erb :error
  end
end

##
# Receive callback from the Evernote authorization page and exchange the
# temporary credentials for an token credentials.
##
get '/callback' do
  if params['oauth_verifier']
    oauth_verifier = params['oauth_verifier']

    begin
      access_token = session[:request_token].get_access_token(:oauth_verifier => oauth_verifier)

      noteStoreTransport = Thrift::HTTPClientTransport.new(access_token.params['edam_noteStoreUrl'])
      noteStoreProtocol = Thrift::BinaryProtocol.new(noteStoreTransport)
      noteStore = Evernote::EDAM::NoteStore::NoteStore::Client.new(noteStoreProtocol)

      # Build an array of notebook names from the array of Notebook objects
      notebooks = noteStore.listNotebooks(access_token.token)
      @notebooks = notebooks.map(&:name)
      erb :complete
    rescue => e
      @last_error = e.message
      erb :error
    end
  else
    @last_error = "Content owner did not authorize the temporary credentials"
    erb :error
  end
end

__END__


@@ layout
<html>
  <head>
    <title>Evernote Ruby OAuth Demo</title>
  </head>
  <body>
    <h1>Evernote Ruby OAuth Demo</h1>

    <p>
      This application uses the <a href="http://www.sinatrarb.com/">Sinatra framework</a> to demonstrate the use of OAuth to authenticate to the Evernote web service. OAuth support is implemented using the <a href="https://github.com/oauth/oauth-ruby">Ruby OAuth RubyGem</a>.
    </p>

    <p>
      On this page, we demonstrate how OAuth authentication might work in the real world.
      To see a step-by-step demonstration of how OAuth works, see <code>evernote_oauth.rb</code>.
    </p>

    <hr/>

    <h2>Evernote Authentication</h2>

    <%= yield %>

    <hr/>
    
    <p>
      <a href="/reset">Click here</a> to start over
    </p>

  </body>
</html>


@@ error
<p>
  <span style="color:red">An error occurred: <%= @last_error %></span>
</p>

@@ authorize
<p>
  <a href="/authorize">Click here</a> to authorize this application to access your Evernote account. You will be directed to evernote.com to authorize access, then returned to this application after authorization is complete.
</p>


@@ complete
<p style="color:green">
  Congratulations, you have successfully authorized this application to access your Evernote account!
</p>

<p>
  You account contains the following notebooks:
</p>

<ul>
  <% @notebooks.each do |notebook| %>
    <li><%= notebook %></li>
  <% end %>
</ul>