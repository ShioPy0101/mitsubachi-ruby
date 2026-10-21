module Demo
  # デモの認証情報は通常の User / Devise session と分離する。
  # この署名から実テナントの権限を付与することはなく、デモ専用 API だけが検証する。
  class Access
    EMAIL = "demo@tenant.example".freeze
    FRONTEND_ORIGIN = "https://demo.mitsubachi.shiosalt.com".freeze
    API_HOST = "mitsubachi-demo-api.shiosalt.com".freeze
    LOGIN_LIFETIME = 15.minutes
    SESSION_LIFETIME = 8.hours

    class InvalidLink < StandardError; end

    def self.issue
      nonce = SecureRandom.uuid
      Rails.cache.write("demo-login:#{nonce}", true, expires_in: LOGIN_LIFETIME)
      token = verifier.generate(nonce, purpose: "demo_login", expires_in: LOGIN_LIFETIME)
      issued_at = Time.current
      url = "#{FRONTEND_ORIGIN}/demo/verify?#{Rack::Utils.build_query(token: token)}"
      body = ActionView::Base.with_empty_template_cache.with_view_paths(
        Rails.root.join("app/views"),
        {
          auth_url: url,
          organizations: [ Struct.new(:name).new("デモテナント") ],
          issued_at: issued_at.iso8601,
          expires_at: (issued_at + LOGIN_LIFETIME).iso8601
        }
      ).render(template: "email_authentication_mailer/login_link", formats: [ :text ])
      { to: EMAIL, subject: "【Mitsubachi】ログインリンクのご案内", body: body, url: url }
    end

    def self.verify(token)
      nonce = verifier.verified(token.to_s, purpose: "demo_login")
      # delete の成功を消費判定に使い、read -> delete 間の並行リクエストによる再利用を避ける。
      raise InvalidLink unless nonce.is_a?(String) && Rails.cache.delete("demo-login:#{nonce}")

      verifier.generate(EMAIL, purpose: "demo_session", expires_in: SESSION_LIFETIME)
    end

    def self.authenticated?(token)
      verifier.verified(token.to_s, purpose: "demo_session") == EMAIL
    end

    def self.verifier
      Rails.application.message_verifier("demo_access")
    end
    private_class_method :verifier
  end
end
