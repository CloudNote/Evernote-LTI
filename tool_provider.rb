require 'sinatra'
require 'ims/lti'
require 'pg'
require 'yaml'
require 'pp'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'
# includes for evernote
require 'oauth'
require 'oauth/consumer'
require 'evernote-thrift'

enable :sessions
set :protection, :except => :frame_options
set :cache, Dalli::Client.new(ENV['MEMCACHE_SERVERS'], 
                              :username => ENV['MEMCACHE_USERNAME'], 
                              :password => ENV['MEMCACHE_PASSWORD'],   
                              :expires_in => 300) 

get '/' do
  erb :index
end

# the consumer keys/secrets
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

# load database and evernote API info
conninfo = YAML.load_file('settings.yml')

# connect to database
dbconn = PG.connect(conninfo["db"]["host"],
                    conninfo["db"]["port"],
                    nil, # options
                    nil, # tty
                    conninfo["db"]["dbname"],
                    conninfo["db"]["user"],
                    conninfo["db"]["password"])
                    
# evernote server information
# replace EVERNOTE_SERVER with https://www.evernote.com
# to use production servers
EVERNOTE_SERVER = "https://sandbox.evernote.com"
REQUEST_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
ACCESS_TOKEN_URL = "#{EVERNOTE_SERVER}/oauth"
AUTHORIZATION_URL = "#{EVERNOTE_SERVER}/OAuth.action"
NOTESTORE_URL_BASE = "#{EVERNOTE_SERVER}/edam/note/"

def show_error(message)
  @message = message
  erb :error
end

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

  # this isn't actually checking anything like it should, just want people
  # implementing real tools to be aware they need to check the nonce
  if was_nonce_used_in_last_x_minutes?(@tp.request_oauth_nonce, 60)
    return show_error "Why are you reusing the nonce?"
  end

  # save the launch parameters for use in later request
  session['launch_params'] = @tp.to_params

  @username = @tp.username("Anonymous")
end

# The url for launching the tool
# It will verify the OAuth signature
post '/lti_tool' do
  authorize!

  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # normal tool launch without grade write-back
    @tp.lti_msg = "Sorry that tool was so boring"
    erb :boring_tool
  end
end

post '/lti_tool_embed' do
  authorize!
  
  # launch from an editor button
  erb :embed
end

# post the assessment results
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

  # post the given score to the TC
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

get '/tool_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/lti_tool"
  tc = IMS::LTI::ToolConfig.new(:title => "Evernote LTI", :launch_url => url)
  tc.description = "Evernote integration for the Canvas LMS"
  tc.icon = "http://evernote.com/media/img/product_icons/evernote-25.png"
  
  editor_params = { "tool_id" => "evernote",
                    "privacy_level" => "anonymous",
                    "editor_button" => 
                    {   "url" => "http://evernote-lti.herokuapp.com/lti_tool_embed",
                        "icon_url" => "http://evernote.com/media/img/product_icons/evernote-25.png",
                        "text" => "Evernote",
                        "selection_width" => 690,
                        "selection_height" => 530,
                        "enabled" => true,  },
                    "resource_selection" =>
                    {   "url" => "http://evernote-lti.herokuapp.com/lti_tool_embed",
                        "icon_url" => "http://evernote.com/media/img/product_icons/evernote-25.png",
                        "text" => "Evernote",
                        "selection_width" => 690,
                        "selection_height" => 530,
                        "enabled" => true,  } }
  
  tc.set_ext_params("canvas.instructure.com", editor_params)

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end

def cache_nonce(nonce, timestamp)
    settings.cache.set(nonce, timestamp) 

end
