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

# Attempt creation of database
begin
    dbconn.exec("CREATE TABLE TOKEN ( LMS_ID text NOT NULL, EVERNOTE_TOKEN text, PRIMARY KEY (LMS_ID) );")
rescue
    # TODO: more robust error handling
end

# Evernote server information
# Replace EVERNOTE_SERVER with https://www.evernote.com
# to use production servers
EVERNOTE_SERVER = "https://sandbox.evernote.com"
REQUEST_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
ACCESS_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
AUTHORIZATION_URL = "#{EVERNOTE_SERVER}/OAuth.action"
NOTESTORE_URL_BASE = "#{EVERNOTE_SERVER}/edam/note/"

##
# Halts execution to show an error page
##
def show_error(message)
  @message = message
  erb :error
end

##
# Authorizes the user during any LTI launch
##
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
  
  # Save the user's ID
  session['uid'] = params[:user_id]
  
  @username = @tp.username("Anonymous")
end

##
# The url for launching the tool
# It will verify the OAuth signature
# TODO: evalute if we need this block at all
##
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

##
# Generate the page when launching from an editor button
# TODO: rename to /lti_tool if we decide not to support non-editor launches
##
post '/lti_tool_embed' do
  authorize!
  
  # Check if we have an active Evernote session
  if session['access_token']
    # Access user's note store
    noteStoreTransport = Thrift::HTTPClientTransport.new(access_token.params['edam_noteStoreUrl'])
    noteStoreProtocol = Thrift::BinaryProtocol.new(noteStoreTransport)
    noteStore = Evernote::EDAM::NoteStore::NoteStore::Client.new(noteStoreProtocol)
    
    # Build an array of notebook names from the array of Notebook objects
    notebooks = noteStore.listNotebooks(access_token.token)
    @notebooks = notebooks.map(&:name)
    
    # Generate the page
    erb :embed
  else
    # Send the user to Evernote for authorization
    erb :authorize
  end
end

##
# Post the assessment results
# TODO: evaluate if we need this
##
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

##
# Generates the LTI tool configuration XML
##
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

##
# Checks if nonce was used recently
##
def was_nonce_used?(nonce)
    timestamp = settings.cache.get(nonce)

    if(!(timestamp.nil?) && (timestamp.to_i < 300) )
        return true # nonce recently used
    else
        return false
    end
end

##
# Caches the nonce
##
def cache_nonce(nonce, timestamp)
    settings.cache.set(nonce, timestamp) 
end

##
# Add a session token to the database
##
def db_addtoken(lmsID, token)
    # TODO: sanitize input?
    dbconn.exec("INSERT INTO TOKEN (lms_id, evernote_token) VALUES ('#{lms_ID},', '#{token}');")
end

##
# Get a session token from the database
##
def db_gettoken(lmsID)
    # TODO: sanitize input?
    dbconn.exec("SELECT evernote_token FROM TOKEN WHERE lms_id = '#{lmsID}'") do |result|
        return result
    end
end

##
# Reset the session
# TODO: evaluate if we need this
##
get '/reset' do
  session.clear
  erb :authorize
end

##
# Get temporary credentials and redirect the user to Evernote for authorization
##
get '/authorize' do
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
    show_error "Error obtaining temporary credentials: #{e.message}"
    erb :error
  end
end

##
# Receive callback from the Evernote authorization page and exchange the
# temporary credentials for access token credentials
##
get '/callback' do
  if params['oauth_verifier']
    oauth_verifier = params['oauth_verifier']

    begin
      # Retrieve access token
      access_token = session[:request_token].get_access_token(:oauth_verifier => oauth_verifier)
      
      # Store access token in database
      db_addtoken(session['uid'], access_token)
      
      # TODO: make this show a relevant page
      erb :index
    rescue => e
      show_error = e.message
      erb :error
    end
  else
    show_error = "Content owner did not authorize the temporary credentials"
    erb :error
  end
end