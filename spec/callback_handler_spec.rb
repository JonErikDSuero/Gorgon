require 'gorgon'

describe CallbackHandler do

  let(:config) {
    {
      :callbacks_class_file => "callback_file.rb"
    }
  }
  before do
    CallbackHandler.any_instance.stub(:load)
  end

  it "loads callback file" do
    CallbackHandler.any_instance.should_receive(:load).with config[:callbacks_class_file]

    CallbackHandler.new(config)
  end

  it "does not load callback file if it's not specified" do
    CallbackHandler.any_instance.should_not_receive(:load)

    CallbackHandler.new({})
  end

  context "#before_originate" do
    it "returns value from callbacks#before_originate if it's a string" do
      handler = CallbackHandler.new(config)
      Gorgon.callbacks.stub(:before_originate).and_return('my_job_id')
      expect(handler.before_originate).to eq('my_job_id')
    end

    it "returns nil if callbacks#before_originate did not return a string" do
      handler = CallbackHandler.new(config)
      Gorgon.callbacks.stub(:before_originate).and_return(Object.new)
      expect(handler.before_originate).to eq(nil)
    end
  end
end
