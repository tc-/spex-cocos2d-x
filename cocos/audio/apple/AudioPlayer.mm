/****************************************************************************
 Copyright (c) 2014 Chukong Technologies Inc.
 
 http://www.cocos2d-x.org
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 ****************************************************************************/

#include "platform/CCPlatformConfig.h"
#if CC_TARGET_PLATFORM == CC_PLATFORM_IOS || CC_TARGET_PLATFORM == CC_PLATFORM_MAC

#import <Foundation/Foundation.h>

#include "AudioPlayer.h"
#include "AudioCache.h"
#include "platform/CCFileUtils.h"
#import <AudioToolbox/ExtendedAudioFile.h>

using namespace cocos2d;
using namespace cocos2d::experimental;

AudioPlayer::AudioPlayer()
: _exitThread(false)
, _timeDirty(false)
, _streamingSource(false)
, _currTime(0.0f)
, _finishCallbak(nullptr)
, _ready(false)
, _audioCache(nullptr)
{
    
}

AudioPlayer::~AudioPlayer()
{
    _exitThread = true;
    if (_audioCache && _audioCache->_queBufferFrames > 0) {
        _sleepCondition.notify_all();
        if (_rotateBufferThread.joinable()) {
            _rotateBufferThread.join();
        }
        alDeleteBuffers(3, _bufferIds);
    }
}

bool AudioPlayer::play2d(AudioCache* cache)
{
    if (!cache->_alBufferReady) {
        return false;
    }
    _audioCache = cache;
    
    alSourcei(_alSource, AL_BUFFER, 0);
    alSourcef(_alSource, AL_PITCH, 1.0f);
    alSourcef(_alSource, AL_GAIN, _volume);
    
    if (_audioCache->_queBufferFrames == 0) {
        if (_loop) {
            alSourcei(_alSource, AL_LOOPING, AL_TRUE);
        }
        else {
            alSourcei(_alSource, AL_LOOPING, AL_FALSE);
        }
        alSourcei(_alSource, AL_BUFFER, _audioCache->_alBufferId);
        
    } else {
        _streamingSource = true;
        
        auto alError = alGetError();
        alGenBuffers(3, _bufferIds);
        alError = alGetError();
        if (alError == AL_NO_ERROR) {
            _rotateBufferThread = std::thread(&AudioPlayer::rotateBufferThread,this, _audioCache->_queBufferFrames * QUEUEBUFFER_NUM + 1);
            
            for (int index = 0; index < QUEUEBUFFER_NUM; ++index) {
                alBufferData(_bufferIds[index], _audioCache->_format, _audioCache->_queBuffers[index], _audioCache->_queBufferSize[index], _audioCache->_sampleRate);
            }
            alSourceQueueBuffers(_alSource, QUEUEBUFFER_NUM, _bufferIds);
        }
        else {
            printf("%s:alGenBuffers error code:%x", __PRETTY_FUNCTION__,alError);
            return false;
        }
    }
    
    alSourcePlay(_alSource);
    _ready = true;
    auto alError = alGetError();
    
    if (alError != AL_NO_ERROR) {
        printf("%s:alSourcePlay error code:%x\n", __PRETTY_FUNCTION__,alError);
        return false;
    }
    
    return true;
}

void AudioPlayer::rotateBufferThread(int offsetFrame)
{
    ALint sourceState;
    ALint bufferProcessed = 0;
    ExtAudioFileRef extRef = nullptr;
    
    auto fileURL = (CFURLRef)[[NSURL fileURLWithPath:[NSString stringWithCString:_audioCache->_fileFullPath.c_str() encoding:[NSString defaultCStringEncoding]]] retain];
    char* tmpBuffer = (char*)malloc(_audioCache->_queBufferBytes);
    auto frames = _audioCache->_queBufferFrames;
    
    auto error = ExtAudioFileOpenURL(fileURL, &extRef);
    if(error) {
        printf("%s: ExtAudioFileOpenURL FAILED, Error = %ld\n", __PRETTY_FUNCTION__,(long) error);
        goto ExitBufferThread;
    }
    
    error = ExtAudioFileSetProperty(extRef, kExtAudioFileProperty_ClientDataFormat, sizeof(_audioCache->outputFormat), &_audioCache->outputFormat);
    AudioBufferList		theDataBuffer;
    theDataBuffer.mNumberBuffers = 1;
    theDataBuffer.mBuffers[0].mData = tmpBuffer;
    theDataBuffer.mBuffers[0].mDataByteSize = _audioCache->_queBufferBytes;
    theDataBuffer.mBuffers[0].mNumberChannels = _audioCache->outputFormat.mChannelsPerFrame;
    
    if (offsetFrame != 0) {
        ExtAudioFileSeek(extRef, offsetFrame);
    }
    
    while (!_exitThread) {
        alGetSourcei(_alSource, AL_SOURCE_STATE, &sourceState);
        if (sourceState == AL_PLAYING) {
            alGetSourcei(_alSource, AL_BUFFERS_PROCESSED, &bufferProcessed);
            while (bufferProcessed > 0) {
                bufferProcessed--;
                if (_timeDirty) {
                    _timeDirty = false;
                    offsetFrame = _currTime * _audioCache->outputFormat.mSampleRate;
                    ExtAudioFileSeek(extRef, offsetFrame);
                }
                else {
                    _currTime += QUEUEBUFFER_TIME_STEP;
                    if (_currTime > _audioCache->_duration) {
                        if (_loop) {
                            _currTime = 0.0f;
                        } else {
                            _currTime = _audioCache->_duration;
                        }
                    }
                }
                
                frames = _audioCache->_queBufferFrames;
                ExtAudioFileRead(extRef, (UInt32*)&frames, &theDataBuffer);
                if (frames <= 0) {
                    if (_loop) {
                        ExtAudioFileSeek(extRef, 0);
                        frames = _audioCache->_queBufferFrames;
                        theDataBuffer.mBuffers[0].mDataByteSize = _audioCache->_queBufferBytes;
                        ExtAudioFileRead(extRef, (UInt32*)&frames, &theDataBuffer);
                    } else {
                        _exitThread = true;
                        break;
                    }
                }
                
                ALuint bid;
                alSourceUnqueueBuffers(_alSource, 1, &bid);
                alBufferData(bid, _audioCache->_format, tmpBuffer, frames * _audioCache->outputFormat.mBytesPerFrame, _audioCache->_sampleRate);
                alSourceQueueBuffers(_alSource, 1, &bid);
            }
        }
        
        if (_exitThread) {
            break;
        }
        std::unique_lock<std::mutex> lk(_sleepMutex);
        _sleepCondition.wait_for(lk,std::chrono::milliseconds(75));
    }
    
ExitBufferThread:
    CFRelease(fileURL);
	// Dispose the ExtAudioFileRef, it is no longer needed
	if (extRef){
        ExtAudioFileDispose(extRef);
    }
    free(tmpBuffer);
}

bool AudioPlayer::setLoop(bool loop)
{
    if (!_exitThread ) {
        _loop = loop;
        return true;
    }
    
    return false;
}

bool AudioPlayer::setTime(float time)
{
    if (!_exitThread && time >= 0.0f && time < _audioCache->_duration) {
        
        _currTime = time;
        _timeDirty = true;
        
        return true;
    }
    return false;
}

#endif
