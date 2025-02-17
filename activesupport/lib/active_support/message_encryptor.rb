# frozen_string_literal: true

require "openssl"
require "base64"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/message_verifier"
require "active_support/messages/metadata"

module ActiveSupport
  # MessageEncryptor is a simple way to encrypt values which get stored
  # somewhere you don't trust.
  #
  # The cipher text and initialization vector are base64 encoded and returned
  # to you.
  #
  # This can be used in situations similar to the <tt>MessageVerifier</tt>, but
  # where you don't want users to be able to determine the value of the payload.
  #
  #   len   = ActiveSupport::MessageEncryptor.key_len
  #   salt  = SecureRandom.random_bytes(len)
  #   key   = ActiveSupport::KeyGenerator.new('password').generate_key(salt, len) # => "\x89\xE0\x156\xAC..."
  #   crypt = ActiveSupport::MessageEncryptor.new(key)                            # => #<ActiveSupport::MessageEncryptor ...>
  #   encrypted_data = crypt.encrypt_and_sign('my secret data')                   # => "NlFBTTMwOUV5UlA1QlNEN2xkY2d6eThYWWh..."
  #   crypt.decrypt_and_verify(encrypted_data)                                    # => "my secret data"
  # The +decrypt_and_verify+ method will raise an
  # <tt>ActiveSupport::MessageEncryptor::InvalidMessage</tt> exception if the data
  # provided cannot be decrypted or verified.
  #
  #   crypt.decrypt_and_verify('not encrypted data') # => ActiveSupport::MessageEncryptor::InvalidMessage
  #
  # === Confining messages to a specific purpose
  #
  # By default any message can be used throughout your app. But they can also be
  # confined to a specific +:purpose+.
  #
  #   token = crypt.encrypt_and_sign("this is the chair", purpose: :login)
  #
  # Then that same purpose must be passed when verifying to get the data back out:
  #
  #   crypt.decrypt_and_verify(token, purpose: :login)    # => "this is the chair"
  #   crypt.decrypt_and_verify(token, purpose: :shipping) # => nil
  #   crypt.decrypt_and_verify(token)                     # => nil
  #
  # Likewise, if a message has no purpose it won't be returned when verifying with
  # a specific purpose.
  #
  #   token = crypt.encrypt_and_sign("the conversation is lively")
  #   crypt.decrypt_and_verify(token, purpose: :scare_tactics) # => nil
  #   crypt.decrypt_and_verify(token)                          # => "the conversation is lively"
  #
  # === Making messages expire
  #
  # By default messages last forever and verifying one year from now will still
  # return the original value. But messages can be set to expire at a given
  # time with +:expires_in+ or +:expires_at+.
  #
  #   crypt.encrypt_and_sign(parcel, expires_in: 1.month)
  #   crypt.encrypt_and_sign(doowad, expires_at: Time.now.end_of_year)
  #
  # Then the messages can be verified and returned up to the expire time.
  # Thereafter, verifying returns +nil+.
  #
  # === Rotating keys
  #
  # MessageEncryptor also supports rotating out old configurations by falling
  # back to a stack of encryptors. Call +rotate+ to build and add an encryptor
  # so +decrypt_and_verify+ will also try the fallback.
  #
  # By default any rotated encryptors use the values of the primary
  # encryptor unless specified otherwise.
  #
  # You'd give your encryptor the new defaults:
  #
  #   crypt = ActiveSupport::MessageEncryptor.new(@secret, cipher: "aes-256-gcm")
  #
  # Then gradually rotate the old values out by adding them as fallbacks. Any message
  # generated with the old values will then work until the rotation is removed.
  #
  #   crypt.rotate old_secret            # Fallback to an old secret instead of @secret.
  #   crypt.rotate cipher: "aes-256-cbc" # Fallback to an old cipher instead of aes-256-gcm.
  #
  # Though if both the secret and the cipher was changed at the same time,
  # the above should be combined into:
  #
  #   crypt.rotate old_secret, cipher: "aes-256-cbc"
  class MessageEncryptor
    prepend Messages::Rotator::Encryptor

    cattr_accessor :use_authenticated_message_encryption, instance_accessor: false, default: false
    cattr_accessor :default_message_encryptor_serializer, instance_accessor: false, default: :marshal

    class << self
      def default_cipher # :nodoc:
        if use_authenticated_message_encryption
          "aes-256-gcm"
        else
          "aes-256-cbc"
        end
      end
    end

    module NullSerializer # :nodoc:
      def self.load(value)
        value
      end

      def self.dump(value)
        value
      end
    end

    module NullVerifier # :nodoc:
      def self.verify(value)
        value
      end

      def self.generate(value)
        value
      end
    end

    class InvalidMessage < StandardError; end
    OpenSSLCipherError = OpenSSL::Cipher::CipherError

    AUTH_TAG_LENGTH = 16 # :nodoc:
    AUTH_TAG_LENGTH_IN_BASE64 = ((4 * AUTH_TAG_LENGTH / 3) + 3) & ~3 # :nodoc:
    SEPARATOR = "--" # :nodoc:
    SEPARATOR_LENGTH = SEPARATOR.length # :nodoc:

    # Initialize a new MessageEncryptor. +secret+ must be at least as long as
    # the cipher key size. For the default 'aes-256-gcm' cipher, this is 256
    # bits. If you are using a user-entered secret, you can generate a suitable
    # key by using <tt>ActiveSupport::KeyGenerator</tt> or a similar key
    # derivation function.
    #
    # First additional parameter is used as the signature key for +MessageVerifier+.
    # This allows you to specify keys to encrypt and sign data.
    #
    #    ActiveSupport::MessageEncryptor.new('secret', 'signature_secret')
    #
    # Options:
    # * <tt>:cipher</tt>     - Cipher to use. Can be any cipher returned by
    #   <tt>OpenSSL::Cipher.ciphers</tt>. Default is 'aes-256-gcm'.
    # * <tt>:digest</tt> - String of digest to use for signing. Default is
    #   +SHA1+. Ignored when using an AEAD cipher like 'aes-256-gcm'.
    # * <tt>:serializer</tt> - Object serializer to use. Default is +JSON+.
    def initialize(secret, sign_secret = nil, cipher: nil, digest: nil, serializer: nil)
      @secret = secret
      @sign_secret = sign_secret
      @cipher = cipher || self.class.default_cipher
      @digest = digest || "SHA1" unless aead_mode?
      @verifier = resolve_verifier
      @serializer = serializer ||
        if @@default_message_encryptor_serializer.equal?(:marshal)
          Marshal
        elsif @@default_message_encryptor_serializer.equal?(:hybrid)
          JsonWithMarshalFallback
        elsif @@default_message_encryptor_serializer.equal?(:json)
          JSON
        end
    end

    # Encrypt and sign a message. We need to sign the message in order to avoid
    # padding attacks. Reference: https://www.limited-entropy.com/padding-oracle-attacks/.
    def encrypt_and_sign(value, expires_at: nil, expires_in: nil, purpose: nil)
      verifier.generate(_encrypt(value, expires_at: expires_at, expires_in: expires_in, purpose: purpose))
    end

    # Decrypt and verify a message. We need to verify the message in order to
    # avoid padding attacks. Reference: https://www.limited-entropy.com/padding-oracle-attacks/.
    def decrypt_and_verify(data, purpose: nil, **)
      _decrypt(verifier.verify(data), purpose)
    end

    # Given a cipher, returns the key length of the cipher to help generate the key of desired size
    def self.key_len(cipher = default_cipher)
      OpenSSL::Cipher.new(cipher).key_len
    end

    private
      def serialize(value)
        @serializer.dump(value)
      end

      def deserialize(value)
        @serializer.load(value)
      end

      def _encrypt(value, **metadata_options)
        cipher = new_cipher
        cipher.encrypt
        cipher.key = @secret

        # Rely on OpenSSL for the initialization vector
        iv = cipher.random_iv
        cipher.auth_data = "" if aead_mode?

        encrypted_data = cipher.update(Messages::Metadata.wrap(serialize(value), **metadata_options))
        encrypted_data << cipher.final

        encoded_encrypted_data = ::Base64.strict_encode64(encrypted_data)
        encoded_iv = ::Base64.strict_encode64(iv)

        if aead_mode?
          encoded_auth_tag = ::Base64.strict_encode64(cipher.auth_tag(AUTH_TAG_LENGTH))
          "#{encoded_encrypted_data}#{SEPARATOR}#{encoded_iv}#{SEPARATOR}#{encoded_auth_tag}"
        else
          "#{encoded_encrypted_data}#{SEPARATOR}#{encoded_iv}"
        end
      end

      def _decrypt(encrypted_message, purpose)
        cipher = new_cipher
        encrypted_data, iv, auth_tag = get_encrypted_data_and_iv_and_auth_tag_from(encrypted_message)

        # Currently the OpenSSL bindings do not raise an error if auth_tag is
        # truncated, which would allow an attacker to easily forge it. See
        # https://github.com/ruby/openssl/issues/63
        raise InvalidMessage if aead_mode? && (auth_tag.nil? || auth_tag.bytes.length != AUTH_TAG_LENGTH)

        cipher.decrypt
        cipher.key = @secret
        cipher.iv  = iv
        if aead_mode?
          cipher.auth_tag = auth_tag
          cipher.auth_data = ""
        end

        decrypted_data = cipher.update(encrypted_data)
        decrypted_data << cipher.final

        message = Messages::Metadata.verify(decrypted_data, purpose)
        deserialize(message) if message
      rescue OpenSSLCipherError, TypeError, ArgumentError, ::JSON::ParserError
        raise InvalidMessage
      end

      def iv_length_in_base64
        @iv_length_in_base64 ||= ((4 * new_cipher.iv_len / 3) + 3) & ~3
      end

      def separator_at?(encrypted_message, index)
        encrypted_message[index, SEPARATOR_LENGTH] == SEPARATOR
      end

      def auth_tag_and_iv_separators_indexes_for(encrypted_message)
        if aead_mode?
          auth_tag_separator_index = encrypted_message.length - AUTH_TAG_LENGTH_IN_BASE64 - SEPARATOR_LENGTH
          return if auth_tag_separator_index < SEPARATOR_LENGTH || !separator_at?(encrypted_message, auth_tag_separator_index)
        end

        iv_separator_index = (auth_tag_separator_index || encrypted_message.length) - iv_length_in_base64 - SEPARATOR_LENGTH
        return if iv_separator_index.negative? || !separator_at?(encrypted_message, iv_separator_index)

        [auth_tag_separator_index, iv_separator_index]
      end

      def get_encrypted_data_and_iv_and_auth_tag_from(encrypted_message)
        auth_tag_separator_index, iv_separator_index = auth_tag_and_iv_separators_indexes_for(encrypted_message)
        return if iv_separator_index.nil? || (aead_mode? && auth_tag_separator_index.nil?)

        encrypted_data = encrypted_message[0, iv_separator_index]
        iv = encrypted_message[iv_separator_index + SEPARATOR_LENGTH, iv_length_in_base64]
        auth_tag = encrypted_message[auth_tag_separator_index + SEPARATOR_LENGTH, AUTH_TAG_LENGTH_IN_BASE64] if aead_mode?

        [encrypted_data, iv, auth_tag].map! { |v| ::Base64.strict_decode64(v) if v.present? }
      end

      def new_cipher
        OpenSSL::Cipher.new(@cipher)
      end

      attr_reader :verifier

      def aead_mode?
        @aead_mode ||= new_cipher.authenticated?
      end

      def resolve_verifier
        if aead_mode?
          NullVerifier
        else
          MessageVerifier.new(@sign_secret || @secret, digest: @digest, serializer: NullSerializer)
        end
      end
  end
end
