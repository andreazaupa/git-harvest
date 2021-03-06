$KCODE = 'u'

require "rubygems"
require "sinatra"
require "json"
require 'base64'
require 'bigdecimal'
require 'date'
require 'jcode'
require 'net/http'
require 'net/https'
require 'time'
require 'openssl'

KEYWORD = "Time"
HAS_SSL = true

get '/' do
  erb :index
end

post '/' do
  erb :index
end

post '/:company/*/:project/:task/:password' do
  payload = JSON.parse(params[:payload])
  
  payload["commits"].each do |commit| 
    if commit["author"]["email"] == params[:splat].to_s && commit["message"].include?(KEYWORD)
      harvest = Harvest.new(params[:company], params[:splat].to_s, params[:project], params[:task], params[:password], commit)
      str = "Thanks" if harvest.save      
    end
  end
  str ||= "No Thanks"
  params.inspect
end

class Harvest

  def initialize(company, email, project, task, encrypted_password, commit)
    @company, @email, @project, @task, @password, @commit = company, email, project, task, encrypted_password.decrypt, commit
    @preferred_protocols = [HAS_SSL, ! HAS_SSL]
    connect!
  end

  # HTTP headers you need to send with every request.
  def headers
    {
      "Accept"        => "application/xml",
      "Content-Type"  => "application/xml; charset=utf-8",
      "Authorization" => "Basic #{auth_string}",
      "User-Agent"    => 'application/github-harvest'
    }
  end

  def auth_string
    Base64.encode64("#{@email}:#{@password}").delete("\r\n")
  end

  def request path, method = :get, body = ""
    response = send_request( path, method, body)
    if response.class < Net::HTTPSuccess
      # response in the 2xx range
      on_completed_request
      return response
    elsif response.class == Net::HTTPServiceUnavailable
      # response status is 503, you have reached the API throttle
      # limit. Harvest will send the "Retry-After" header to indicate
      # the number of seconds your boot needs to be silent.
      raise "Got HTTP 503 three times in a row" if retry_counter > 3
      sleep(response['Retry-After'].to_i + 5)
      request(path, method, body)
    elsif response.class == Net::HTTPFound
      # response was a redirect, most likely due to protocol
      # mismatch. Retry again with a different protocol.
      @preferred_protocols.shift
      raise "Failed connection using http or https" if @preferred_protocols.empty?
      connect!
      request(path, method, body)
    else
      dump_headers = response.to_hash.map { |h,v| [h.upcase,v].join(': ') }.join("\n")
      raise "#{response.message} (#{response.code})\n\n#{dump_headers}\n\n#{response.body}\n"
    end
  end
  
  def note
    @commit["message"].split(KEYWORD)[0].strip
  end

  def time_spent
    @commit["message"].split(KEYWORD)[1].strip
  end
  
  def save
    request('/daily/add', :post, "<request><notes>#{note}</notes><hours>#{time_spent}</hours><project_id type='integer'>#{@project}</project_id><task_id type='integer'>#{@task}</task_id><spent_at type='date'>#{Time.parse(@commit["timestamp"]).strftime("%a, %e %b %Y")}</spent_at></request>").body
  end

  private

  def connect!
    port = has_ssl ? 443 : 80
    @connection             = Net::HTTP.new("#{@company}.harvestapp.com", port)
    @connection.use_ssl     = has_ssl
    @connection.verify_mode = OpenSSL::SSL::VERIFY_NONE if has_ssl
  end

  def has_ssl
    @preferred_protocols.first
  end

  def send_request path, method = :get, body = ''
    case method
    when :get
      @connection.get(path, headers)
    when :post
      @connection.post(path, body, headers)
    when :put
      @connection.put(path, body, headers)
    when :delete
      @connection.delete(path, headers)
    end
  end

  def on_completed_request
    @retry_counter = 0
  end

  def retry_counter
    @retry_counter ||= 0
    @retry_counter += 1
  end

end

# http://jasondanielong.multiply.com/journal/item/181/Facets_of_Ruby_Simple_encryption_for_dummies
class String
  def self.cypher
    ["a-zA-Z0-9+_", "c-zab0-9D-ZABC_+"]
  end
  
  def encrypt
    tr String.cypher[0], String.cypher[1]
  end

  def decrypt
    tr String.cypher[1], String.cypher[0]
  end
end
