module Spaceship
  class Client
    def handle_two_step(response)
      if load_session_from_file
        return true
      end

      @x_apple_web_session_token = response["x-apple-web-session-token"]
      @scnt = response["scnt"]

      r = request(:get) do |req|
        req.url "https://idmsa.apple.com/appleauth/auth"
        req.headers["scnt"] = @scnt
        req.headers["X-Apple-Web-Session-Token"] = @x_apple_web_session_token
        req.headers["Accept"] = "application/json"
      end

      if r.body.kind_of?(Hash) && r.body["trustedDevices"].kind_of?(Array)
        if r.body.fetch("securityCode", {})["tooManyCodesLock"].to_s.length > 0
          raise ITunesConnectError.new, "Too many verification codes have been sent. Enter the last code you received, use one of your devices, or try again later."
        end

        old_client = (begin
                        Tunes::RecoveryDevice.client
                      rescue
                        nil # since client might be nil, which raises an exception
                      end)
        Tunes::RecoveryDevice.client = self # temporary set it as it's required by the factory method
        devices = r.body["trustedDevices"].collect do |current|
          Tunes::RecoveryDevice.factory(current)
        end
        Tunes::RecoveryDevice.client = old_client

        puts "Two Step Verification for account '#{self.user}' is enabled"
        puts "Please select a device to verify your identity"
        available = devices.collect do |c|
          "#{c.name}\t#{c.model_name || 'SMS'}\t(#{c.device_id})"
        end
        result = choose(*available)
        device_id = result.match(/.*\t.*\t\((.*)\)/)[1]
        select_device(r, device_id)
      else
        raise "Invalid 2 step response #{r.body}"
      end
    end

    # Only needed for 2 step
    def load_session_from_file
      if File.exist?(persistent_cookie_path)
        @cookie.load(persistent_cookie_path)
        if self.team_id.to_s.length > 0 # this will send a request that will fail if the cookie is invalid
          return true
        else
          File.delete(persistent_cookie_path) # session is already invalid
        end
      end
      return false
    end

    def select_device(r, device_id)
      # Request Token
      r = request(:put) do |req|
        req.url "https://idmsa.apple.com/appleauth/auth/verify/device/#{device_id}/securitycode"
        req.headers["Accept"] = "application/json"
        req.headers["scnt"] = @scnt
        req.headers["X-Apple-Web-Session-Token"] = @x_apple_web_session_token
      end

      # we use `Spaceship::TunesClient.new.handle_itc_response`
      # since this might be from the Dev Portal, but for 2 step
      Spaceship::TunesClient.new.handle_itc_response(r.body)

      puts "Successfully requested notification"
      code = ask("Please enter the 4 digit code: ")
      puts "Requesting session..."

      # Send token back to server to get a valid session
      r = request(:post) do |req|
        req.url "https://idmsa.apple.com/appleauth/auth/verify/device/#{device_id}/securitycode"
        req.headers["Accept"] = "application/json"
        req.headers["scnt"] = @scnt
        req.headers["X-Apple-Web-Session-Token"] = @x_apple_web_session_token
        req.body = { "code" => code.to_s }.to_json
        req.headers['Content-Type'] = 'application/json'
      end

      begin
        Spaceship::TunesClient.new.handle_itc_response(r.body) # this will fail if the code is invalid
      rescue => ex
        raise "Incorrect verification code" if ex.to_s.include?("verification code") # to have a nicer output
        raise ex
      end

      # If it works, r.body is actually nil
      raise "Could not login" unless r.headers["set-cookie"].include?("myacinfo")

      # Tell iTC that we are trustworthy (obviously)
      # This will update our local cookies to something new
      # They probably have a longer time to live than the other poor cookies
      # Changed Keys
      # - myacinfo
      # - DES5c148586dfd451e55afb0175f62418f91

      request(:get) do |req|
        req.url "https://idmsa.apple.com/appleauth/auth/2sv/trust"
        req.headers["scnt"] = @scnt
        req.headers["X-Apple-Web-Session-Token"] = @x_apple_web_session_token
      end

      # We want to store the myacinfo cookie
      @cookie.save(persistent_cookie_path, :yaml, session: true)
      # really important to specify the session
      # otherwise myacinfo and more won't be stored

      return true
    end

    def persistent_cookie_path
      path = File.expand_path(File.join("~", ".spaceship", self.user, "cookie"))
      FileUtils.mkdir_p(File.expand_path("..", path))
      return path
    end
  end
end