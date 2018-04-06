require 'spec_helper'

describe Ci::JobTraceChunk, :clean_gitlab_redis_shared_state do
  set(:job) { create(:ci_build, :running) }
  let(:chunk_index) { 0 }
  let(:data_store) { :redis }
  let(:raw_data) { nil }

  let(:job_trace_chunk) do
    described_class.new(job: job, chunk_index: chunk_index, data_store: data_store, raw_data: raw_data)
  end

  describe 'CHUNK_SIZE' do
    it 'Chunk size can not be changed without special care' do
      expect(described_class::CHUNK_SIZE).to eq(128.kilobytes)
    end
  end

  describe '#data' do
    subject { job_trace_chunk.data }

    context 'when data_store is redis' do
      let(:data_store) { :redis }

      before do
        job_trace_chunk.send(:redis_set_data, 'Sample data in redis')
      end

      it { is_expected.to eq('Sample data in redis') }
    end

    context 'when data_store is database' do
      let(:data_store) { :db }
      let(:raw_data) { 'Sample data in db' }

      it { is_expected.to eq('Sample data in db') }
    end

    context 'when data_store is others' do
      before do
        job_trace_chunk.send(:write_attribute, :data_store, -1)
      end

      it { expect { subject }.to raise_error('Unsupported data store') }
    end
  end

  describe '#set_data' do
    subject { job_trace_chunk.set_data(value) }

    let(:value) { 'Sample data' }

    context 'when value bytesize is bigger than CHUNK_SIZE' do
      let(:value) { 'a' * (described_class::CHUNK_SIZE + 1) }

      it { expect { subject }.to raise_error('too much data') }
    end

    context 'when data_store is redis' do
      let(:data_store) { :redis }

      it do
        expect(job_trace_chunk.send(:redis_data)).to be_nil

        subject

        expect(job_trace_chunk.send(:redis_data)).to eq(value)
      end

      context 'when fullfilled chunk size' do
        let(:value) { 'a' * described_class::CHUNK_SIZE }

        it 'schedules stashing data' do
          expect(SwapTraceChunkWorker).to receive(:perform_async).once

          subject
        end
      end
    end

    context 'when data_store is database' do
      let(:data_store) { :db }

      it 'sets data' do
        expect(job_trace_chunk.raw_data).to be_nil

        subject

        expect(job_trace_chunk.raw_data).to eq(value)
        expect(job_trace_chunk.persisted?).to be_truthy
      end

      context 'when raw_data is not changed' do
        it 'does not execute UPDATE' do
          expect(job_trace_chunk.raw_data).to be_nil
          job_trace_chunk.save!

          # First set
          expect(ActiveRecord::QueryRecorder.new { subject }.count).to be > 0
          expect(job_trace_chunk.raw_data).to eq(value)
          expect(job_trace_chunk.persisted?).to be_truthy

          # Second set
          job_trace_chunk.reload
          expect(ActiveRecord::QueryRecorder.new { subject }.count).to be(0)
        end
      end

      context 'when fullfilled chunk size' do
        it 'does not schedule stashing data' do
          expect(SwapTraceChunkWorker).not_to receive(:perform_async)

          subject
        end
      end
    end

    context 'when data_store is others' do
      before do
        job_trace_chunk.send(:write_attribute, :data_store, -1)
      end

      it { expect { subject }.to raise_error('Unsupported data store') }
    end
  end

  describe '#truncate' do
    subject { job_trace_chunk.truncate(offset) }

    shared_examples_for 'truncates' do
      context 'when offset is negative' do
        let(:offset) { -1 }

        it { expect { subject }.to raise_error('Offset is out of bound') }
      end

      context 'when offset is bigger than data size' do
        let(:offset) { data.bytesize + 1 }

        it { expect { subject }.to raise_error('Offset is out of bound') }
      end

      context 'when offset is 10' do
        let(:offset) { 10 }

        it 'truncates' do
          subject

          expect(job_trace_chunk.data).to eq(data.byteslice(0, offset))
        end
      end
    end

    context 'when data_store is redis' do
      let(:data_store) { :redis }
      let(:data) { 'Sample data in redis' }

      before do
        job_trace_chunk.send(:redis_set_data, data)
      end

      it_behaves_like 'truncates'
    end

    context 'when data_store is database' do
      let(:data_store) { :db }
      let(:raw_data) { 'Sample data in db' }
      let(:data) { raw_data }

      it_behaves_like 'truncates'
    end
  end

  describe '#append' do
    subject { job_trace_chunk.append(new_data, offset) }

    let(:new_data) { 'Sample new data' }
    let(:offset) { 0 }
    let(:total_data) { data + new_data }

    shared_examples_for 'appends' do
      context 'when offset is negative' do
        let(:offset) { -1 }

        it { expect { subject }.to raise_error('Offset is out of bound') }
      end

      context 'when offset is bigger than data size' do
        let(:offset) { data.bytesize + 1 }

        it { expect { subject }.to raise_error('Offset is out of bound') }
      end

      context 'when offset is bigger than data size' do
        let(:new_data) { 'a' * (described_class::CHUNK_SIZE + 1) }

        it { expect { subject }.to raise_error('Outside of chunk size') }
      end

      context 'when offset is EOF' do
        let(:offset) { data.bytesize }

        it 'appends' do
          subject

          expect(job_trace_chunk.data).to eq(total_data)
        end
      end

      context 'when offset is 10' do
        let(:offset) { 10 }

        it 'appends' do
          subject

          expect(job_trace_chunk.data).to eq(data.byteslice(0, offset) + new_data)
        end
      end
    end

    context 'when data_store is redis' do
      let(:data_store) { :redis }
      let(:data) { 'Sample data in redis' }

      before do
        job_trace_chunk.send(:redis_set_data, data)
      end

      it_behaves_like 'appends'
    end

    context 'when data_store is database' do
      let(:data_store) { :db }
      let(:raw_data) { 'Sample data in db' }
      let(:data) { raw_data }

      it_behaves_like 'appends'
    end
  end

  describe '#size' do
    subject { job_trace_chunk.size }

    context 'when data_store is redis' do
      let(:data_store) { :redis }

      context 'when data exists' do
        let(:data) { 'Sample data in redis' }

        before do
          job_trace_chunk.send(:redis_set_data, data)
        end

        it { is_expected.to eq(data.bytesize) }
      end

      context 'when data exists' do
        it { is_expected.to eq(0) }
      end
    end

    context 'when data_store is database' do
      let(:data_store) { :db }

      context 'when data exists' do
        let(:raw_data) { 'Sample data in db' }
        let(:data) { raw_data }

        it { is_expected.to eq(data.bytesize) }
      end

      context 'when data does not exist' do
        it { is_expected.to eq(0) }
      end
    end
  end

  describe '#use_database!' do
    subject { job_trace_chunk.use_database! }

    context 'when data_store is redis' do
      let(:data_store) { :redis }

      context 'when data exists' do
        let(:data) { 'Sample data in redis' }

        before do
          job_trace_chunk.send(:redis_set_data, data)
        end

        it 'stashes the data' do
          expect(job_trace_chunk.data_store).to eq('redis')
          expect(job_trace_chunk.send(:redis_data)).to eq(data)
          expect(job_trace_chunk.raw_data).to be_nil

          subject

          expect(job_trace_chunk.data_store).to eq('db')
          expect(job_trace_chunk.send(:redis_data)).to be_nil
          expect(job_trace_chunk.raw_data).to eq(data)
        end
      end

      context 'when data does not exist' do
        it 'does not call UPDATE' do
          expect(ActiveRecord::QueryRecorder.new { subject }.count).to eq(0)
        end
      end
    end

    context 'when data_store is database' do
      let(:data_store) { :db }

      it 'does not call UPDATE' do
        expect(ActiveRecord::QueryRecorder.new { subject }.count).to eq(0)
      end
    end
  end

  describe 'ExclusiveLock' do
    before do
      allow_any_instance_of(Gitlab::ExclusiveLease).to receive(:try_obtain) { nil }
      stub_const('Ci::JobTraceChunk::LOCK_RETRY', 1)
    end

    it 'raise an error' do
      expect { job_trace_chunk.append('ABC', 0) }.to raise_error('Failed to obtain write lock')
    end
  end

  describe 'deletes data in redis after chunk record destroyed' do
    let(:project) { create(:project) }

    before do
      pipeline = create(:ci_pipeline, project: project)
      create(:ci_build, :running, :trace_live, pipeline: pipeline, project: project)
      create(:ci_build, :running, :trace_live, pipeline: pipeline, project: project)
      create(:ci_build, :running, :trace_live, pipeline: pipeline, project: project)
    end

    shared_examples_for 'deletes all job_trace_chunk and data in redis' do
      it do
        project.builds.each do |build|
          Gitlab::Redis::SharedState.with do |redis|
            redis.scan_each(match: "gitlab:ci:trace:#{build.id}:chunks:?") do |key|
              expect(redis.exists(key)).to be_truthy
            end
          end
        end

        expect(described_class.count).not_to eq(0)

        subject

        expect(described_class.count).to eq(0)

        project.builds.each do |build|
          Gitlab::Redis::SharedState.with do |redis|
            redis.scan_each(match: "gitlab:ci:trace:#{build.id}:chunks:?") do |key|
              expect(redis.exists(key)).to be_falsey
            end
          end
        end
      end
    end

    context 'when job_trace_chunk is destroyed' do
      let(:subject) do
        project.builds.each { |build| build.chunks.destroy_all }
      end

      it_behaves_like 'deletes all job_trace_chunk and data in redis'
    end

    context 'when job is destroyed' do
      let(:subject) do
        project.builds.destroy_all
      end

      it_behaves_like 'deletes all job_trace_chunk and data in redis'
    end

    context 'when project is destroyed' do
      let(:subject) do
        project.destroy!
      end

      it_behaves_like 'deletes all job_trace_chunk and data in redis'
    end
  end
end
