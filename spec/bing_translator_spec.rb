require_relative 'spec_helper'

describe BingTranslator do
  include RSpecHtmlMatchers

  def load_file(filename)
    File.read(File.join(File.dirname(__FILE__), 'etc', filename))
  end

  let(:api_key) { ENV.fetch('COGNITIVE_SUBSCRIPTION_KEY') }
  let(:message_en) { 'This message should be translated' }
  let(:message_en_other) { 'This message should be too translated' }
  let(:long_text) { load_file('long_text') }
  let(:long_unicode_text) { load_file('long_unicode_text.txt') }
  let(:long_html_text) { load_file('long_text.html') }

  let(:translator) { described_class.new(api_key, skip_ssl_verify: false) }

  # These are integration tests, require actual subscription key to be present in the
  # env variable COGNITIVE_SUBSCRIPTION_KEY.
  describe '#translate' do
    it 'translates text' do
      result = translator.translate message_en, from: :en, to: :ru
      expect(result).to eq 'Это сообщение должно быть переведено'

      result = translator.translate message_en, from: :en, to: :fr
      expect(result).to eq 'Ce message doit être traduit'

      result = translator.translate message_en, from: :en, to: :de
      expect(result).to eq 'Diese Nachricht sollte übersetzt werden'
    end

    it 'translates long texts (up to allowed limit)' do
      result = translator.translate long_text, from: :en, to: :ru
      expect(result.size).to be > 1000

      result = translator.translate long_unicode_text, from: :ru, to: :en
      expect(result.size).to be > (long_unicode_text.size / 2) # I assume that the translation couldn't be two times smaller, than the original
    end

    it 'translates texts in html' do
      result = translator.translate long_html_text, from: :en, to: :ru, textType: 'html'
      expect(result.size).to be > 1000
      expect(result.to_s).to have_tag('p')
      expect(result.to_s).to have_tag('code')
    end

    it 'translates text with language autodetection' do
      result = translator.translate message_en, to: :ru
      expect(result).to eq 'Это сообщение должно быть переведено'

      result = translator.translate 'Ce message devrait être traduit', to: :en
      expect(result).to eq message_en

      result = translator.translate 'Diese Meldung sollte übersetzt werden', to: :en
      expect(result).to eq message_en
    end

    context 'when invalid language is specified' do
      it 'throws a reasonable error' do
        expect { translator.translate 'hola', from: :invlaid, to: :en }
          .to raise_error(BingTranslator::Exception)
      end
    end
  end

  describe '#translate_array' do
    it 'translates array of texts' do
      result = translator.translate_array [message_en, message_en_other], from: :en, to: :fr
      expect(result).to eq ['Ce message doit être traduit', 'Ce message doit être trop traduit']
    end
  end

  describe '#translate_array2' do
    it 'translates array of texts, with word alignment information' do
      result = translator.translate_array2 [message_en, message_en_other], from: :en, to: :de
      expect(result).to eq [['Diese Nachricht sollte übersetzt werden',
                             '0:3-0:4 5:11-6:14 13:18-16:21 20:21-33:38 23:32-23:31'],
                            ['Diese Nachricht sollte zu übersetzt werden',
                             '0:3-0:4 5:11-6:14 13:18-16:21 20:21-36:41 23:25-23:24 27:36-26:34']]
    end
  end

  describe '#detect' do
    it 'detects language by passed text' do
      result = translator.detect message_en
      expect(result).to eq :en

      result = translator.detect ' '
      expect(result).to eq :en # Apparently that's what is returned by Bing

      result = translator.detect 'Это сообщение должно быть переведено'
      expect(result).to eq :ru

      result = translator.detect 'Diese Meldung sollte übersetzt werden'
      expect(result).to eq :de
    end
  end

  describe 'supported_language_codes' do
    it 'lists supported language codes' do
      result = translator.supported_language_codes
      expect(result).to include('en')
      expect(result).to include('es')
      expect(result).to include('de')
    end
  end

  describe '#language_names' do
    it 'converts language codes to full names' do
      expect(translator.language_names(%w[en es de])).to eq(%w[English Spanish German])
    end

    context 'when second argument with target language is used' do
      it 'converts the codes to full names in requested language'do
        expect(translator.language_names(%w[en es de], 'de')).to eq(%w[Englisch Spanisch Deutsch])
      end
    end
  end

  context 'when credentials are invalid' do
    let(:translator) { BingTranslator.new('') }

    subject { translator.translate 'hola', from: :es, to: :en }

    it 'throws a BingTranslator::Exception exception' do
      expect { subject }.to raise_error(BingTranslator::Exception)
    end

    context 'trying to translate something twice' do
      it 'throws the BingTranslator::Exception exception every time' do
        2.times { expect { subject }.to raise_error(BingTranslator::Exception) }
      end
    end
  end

  describe BingTranslator::ApiClient do
    let(:instance) { described_class.new('dumb-key', false) }
    let(:params) { {} }
    let(:headers) { {} }
    let(:authorization) { true }
    let(:path) { '/path' }
    let(:response_code) { 200 }
    let(:response_body) { {}.to_json }
    let(:url_params) { '?api-version=3.0' }

    let!(:authorization_stub) do
      stub_request(:post, described_class::COGNITIVE_ACCESS_TOKEN_URI)
        .with(headers: {
          'Ocp-Apim-Subscription-Key' => 'dumb-key'
        })
        .to_return(status: 200, body: 'token', headers: {})
    end

    describe '#post' do
      def action
        instance.post(path, params: params, headers: headers, authorization: authorization)
      end
      subject { action }

      let!(:request_stub) do
        stub_request(:post, "#{described_class::API_HOST}#{path}#{url_params}")
          .with(headers: {
            'Authorization' => 'Bearer token',
            'Content-Type' => 'application/json'
          })
          .to_return(status: response_code, body: response_body, headers: {})
      end

      it 'obtains a new authentication token' do
        subject
        expect(authorization_stub).to have_been_requested
      end

      context 'when API returns an error response' do
        let(:response_code) { 400 }

        it 'throws an error' do
          expect { subject }.to raise_error(BingTranslator::Exception)
        end
      end

      context 'when API request is made two times' do
        it 'caches the authorization token' do
          2.times { action }
          expect(authorization_stub).to have_been_requested.once
        end

        context 'but the last request was made more than 8 minutes ago' do
          it 'requests a new token' do
            action
            Timecop.travel(Time.now + 481)
            action
            expect(authorization_stub).to have_been_requested.twice
            Timecop.return
          end
        end
      end
    end
  end
end
