require 'sinatra'
require 'ims/lti'
require 'pg'
require 'yaml'
require 'dalli'
# Must include the oauth proxy object
require 'oauth/request_proxy/rack_request'
# Includes for evernote
require 'oauth'
require 'oauth/consumer'
require 'evernote-thrift'
#require 'evernote-oauth'

# Enable session storing in cookies
# TODO: change the secret
use Rack::Session::Cookie, :key => 'rack.session',
                               :expire_after => 86400
# Disable Rack frame embedding protection
set :protection, :except => :frame_options
# Enable memcached usage through Dalli
set :cache, Dalli::Client.new(ENV['MEMCACHE_SERVERS'], 
                              :username => ENV['MEMCACHE_USERNAME'], 
                              :password => ENV['MEMCACHE_PASSWORD'],   
                              :expires_in => 300) 

# The consumer keys/secrets
# TODO: figure out what to do with these
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

# Load database and evernote API info
conninfo = YAML.load_file('settings.yml')

# Connect to database
$dbconn = PG.connect(conninfo["db"]["host"],
                    conninfo["db"]["port"],
                    nil, # options
                    nil, # tty
                    conninfo["db"]["dbname"],
                    conninfo["db"]["user"],
                    conninfo["db"]["password"])

# Attempt creation of database
begin
  $dbconn.exec("CREATE TABLE TOKEN ( LMS_ID text NOT NULL, EVERNOTE_TOKEN text, EVERNOTE_NOTESTOREURL text, EXPIRES timestamp, PRIMARY KEY (LMS_ID) );")
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
  @header = "Error"
  @message = message
  erb :error
end

##
# Authorizes the user during any LTI launch
##
def authorize!
  # Ensure keys match
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
  
  # Ensure OAuth signature is valid
  if !@tp.valid_request?(request)
    return show_error "The OAuth signature was invalid"
  end

  # Ensure timestamp is valid
  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    return show_error "Your request is too old."
  end

  # Ensure nonce is valid
  if was_nonce_used?(@tp.request_oauth_nonce)
    return show_error "Why are you reusing the nonce?"
  else
    cache_nonce(@tp.request_oauth_nonce, @tp.request_oauth_timestamp.to_i)
  end
  
  # Save the launch parameters for use in later requests
  session[:launch_params] = @tp.to_params

  # Get the username, using "Anonymous" as a default if none exists
  @username = @tp.username("Anonymous")
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
def db_addToken(lmsID, token, notestoreurl, expires)
  # TODO: sanitize input?
  # TODO: Error handling for re-authorized LMS_ID?
  $dbconn.query("INSERT INTO TOKEN (lms_id, evernote_token, evernote_notestoreurl, expires) VALUES ('#{lmsID}', '#{token}', '#{notestoreurl}', to_timestamp(#{expires}));")
end

##
# Get a session token from the database
##
def db_getToken(lmsID)
  # TODO: sanitize input?
  result = $dbconn.query("SELECT evernote_token, evernote_notestoreurl, expires FROM TOKEN WHERE lms_id = '#{lmsID}'")
  
  if result.num_tuples.zero?
    # No results
    return nil
  else
    # Return a hash of the result
    return result[0]
  end
end

##
# Generates the index page
##
get '/' do
  @header = "Evernote LTI"
  erb :index
end

##
# Generates the LTI tool configuration XML
##
get '/tool_config.xml' do
  # Set LMS parameters
  host = request.scheme + "://" + request.host_with_port
  url = host + "/lti_tool"
  tc = IMS::LTI::ToolConfig.new(:title => "Evernote LTI", :launch_url => url)
  tc.description = "Evernote integration for the Canvas LMS"
  
  # Extended params for Canvas LTI editor buttons
  editor_params = { "tool_id" => "evernote",
                    "privacy_level" => "anonymous",
                    "editor_button" => 
                    { "url" => "http://evernote-lti.herokuapp.com/lti_tool",
                      "icon_url" => "http://evernote-lti.herokuapp.com/favicon.ico",
                      "text" => "Evernote",
                      "selection_width" => 690,
                      "selection_height" => 530,
                      "enabled" => true,  },
                    "resource_selection" =>
                    { "url" => "http://evernote-lti.herokuapp.com/lti_tool",
                      "icon_url" => "http://evernote-lti.herokuapp.com/favicon.ico",
                      "text" => "Evernote",
                      "selection_width" => 690,
                      "selection_height" => 530,
                      "enabled" => true,  } }
  
  tc.set_ext_params("canvas.instructure.com", editor_params)

  # Set MIME headers and return page
  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

##
# Generate the page when launching from an editor button
##
post '/lti_tool' do
  # Verify the launch parameters
  authorize!

  # Get access token from the database
  access_token = db_getToken(params[:user_id])
  
  # Check if we have an active Evernote session
  if access_token
    # Access user's note store
    noteStoreTransport = Thrift::HTTPClientTransport.new(access_token['evernote_notestoreurl'])
    noteStoreProtocol = Thrift::BinaryProtocol.new(noteStoreTransport)
    noteStore = Evernote::EDAM::NoteStore::NoteStore::Client.new(noteStoreProtocol)
    
    # Create an empty hash for notebooks
    @notebooks = Hash.new
    
    # Build a hash of Notebook objects containing Note objects
    usernotebooks = noteStore.listNotebooks(access_token['evernote_token'])
    # Only ask for the GUID and title from the Evernote servers
    resultspec = Evernote::EDAM::NoteStore::NotesMetadataResultSpec.new(:includeTitle => true)
    # Get the max note count
    maxnotes = Evernote::EDAM::Limits::EDAM_USER_NOTES_MAX
    
    usernotebooks.each() do |notebook|
      # Filter for notes in this notebook
      filter = Evernote::EDAM::NoteStore::NoteFilter.new(:notebookGuid => notebook.guid)
      # Retrieve notes
      @notebooks[notebook.guid] =   {:notebook => notebook,
                                     :notelist => noteStore.findNotesMetadata(
                                       access_token['evernote_token'], filter, 0, maxnotes, resultspec)
                                    }
    end
    
    #@notebooks = notebooks.map(&:name)
    
    # Generate the page
    @header = "Embed a note"
    erb :embed
  else
    # Send the user to Evernote for authorization
    @header = "Authorization required"
    erb :authorize
  end
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
  end
end

##
# Receive callback from the Evernote authorization page and exchange the
# temporary credentials for access token credentials
##
get '/callback' do
  # Ensure we have all necessary data
  if params['oauth_verifier'] and session[:launch_params]
    oauth_verifier = params['oauth_verifier']

    begin
      # Retrieve access token
      access_token = session[:request_token].get_access_token(:oauth_verifier => oauth_verifier)
      
      # Store access token in database
      db_addToken(session[:launch_params]['user_id'], access_token.token, access_token.params['edam_noteStoreUrl'], access_token.params['edam_expires'])
      
      #erb :successful_auth
      @header = "Authorization successful"
      erb :successful_auth
    rescue => e
      show_error = e.message
    end
  else
    show_error = "Content owner did not authorize the temporary credentials"
  end
end