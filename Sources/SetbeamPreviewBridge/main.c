/*
 * Setbeam local playback bridge. MIT, like the rest of Setbeam.
 * Linked against the pinned LGPL FFmpeg runtime as a separate executable.
 * stdout is a framed binary stream; stderr is reserved for diagnostics.
 */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { HEADER_BYTES = 64, VIDEO = 1, AUDIO = 2, STREAMS = 3 };
static volatile sig_atomic_t stopping;
static void interrupted(int signal_number) { (void)signal_number; stopping = 1; }
static int interrupt_io(void *unused) { (void)unused; return stopping; }
static void le32(uint8_t *out, uint32_t value) { for (int i=0;i<4;i++) out[i]=(uint8_t)(value>>(8*i)); }
static void le64(uint8_t *out, int64_t value) { for (int i=0;i<8;i++) out[i]=(uint8_t)((uint64_t)value>>(8*i)); }
static int write_all(const uint8_t *data, size_t length) {
    while (length && !stopping) { ssize_t count=write(STDOUT_FILENO,data,length); if(count<=0)return -1; data+=count;length-=count; }
    return stopping ? -1 : 0;
}
static int record(int kind, int flags, int64_t pts, int64_t duration, int width, int height,
                  int channels, int rate, AVRational aspect, int matrix, const uint8_t *data, size_t size) {
    uint8_t header[HEADER_BYTES]={ 'S','B','P','F',1,0,0,0 }; header[6]=(uint8_t)kind;
    le32(header+8,(uint32_t)size); le32(header+12,flags);le64(header+16,pts);le64(header+24,duration);
    le32(header+32,width);le32(header+36,height);le32(header+40,channels);le32(header+44,rate);
    le32(header+48,aspect.num);le32(header+52,aspect.den);le32(header+56,kind==VIDEO?1:kind==AUDIO?2:0);le32(header+60,matrix);
    if(write_all(header,sizeof(header))<0)return -1;
    return size?write_all(data,size):0;
}
typedef struct Decoder {
    AVCodecContext *codec;
    AVStream *stream;
    int index;
    int64_t next_pts;
} Decoder;
static int open_decoder(AVFormatContext *input, enum AVMediaType type, Decoder *out) {
    out->index=av_find_best_stream(input,type,-1,-1,NULL,0);
    if(out->index<0)return out->index;
    out->stream=input->streams[out->index];
    const AVCodec *codec=avcodec_find_decoder(out->stream->codecpar->codec_id);
    if(!codec)return AVERROR_DECODER_NOT_FOUND;
    out->codec=avcodec_alloc_context3(codec);
    if(!out->codec)return AVERROR(ENOMEM);
    int error=avcodec_parameters_to_context(out->codec,out->stream->codecpar);
    if(error<0)return error;
    out->codec->thread_count=2;
    out->codec->thread_type=FF_THREAD_SLICE;
    out->codec->pkt_timebase=out->stream->time_base;
    return avcodec_open2(out->codec,codec,NULL);
}
static int64_t timestamp(Decoder *decoder, const AVFrame *frame, int64_t duration) {
    int64_t pts=frame->best_effort_timestamp;
    pts=pts==AV_NOPTS_VALUE?decoder->next_pts:av_rescale_q(pts,decoder->stream->time_base,AV_TIME_BASE_Q);
    decoder->next_pts=pts+duration;
    return pts;
}
int main(int argc,char **argv) {
    if(argc<2) { fprintf(stderr,"Usage: setbeam-preview URL [--silent] [--width N] [--fps N]\n");return 2; }
    int silent=0,max_width=0,max_fps=0;
    for(int i=2;i<argc;i++) {
        if(!strcmp(argv[i],"--silent"))silent=1;
        else if(!strcmp(argv[i],"--width")&&i+1<argc)max_width=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--fps")&&i+1<argc)max_fps=atoi(argv[++i]);
        else { fprintf(stderr,"Invalid playback option\n");return 2; }
    }
    signal(SIGTERM,interrupted);signal(SIGINT,interrupted);signal(SIGPIPE,interrupted);
    av_log_set_level(AV_LOG_ERROR);avformat_network_init();
    AVFormatContext *input=avformat_alloc_context();
    if(!input)return 1;
    input->interrupt_callback=(AVIOInterruptCB){interrupt_io,NULL};
    AVDictionary *options=NULL;
    av_dict_set(&options,"rtsp_transport","tcp",0);av_dict_set(&options,"rw_timeout","5000000",0);
    av_dict_set(&options,"analyzeduration","2000000",0);av_dict_set(&options,"probesize","1000000",0);
    av_dict_set(&options,"fpsprobesize","0",0);av_dict_set(&options,"max_ts_probe","0",0);
    int result=avformat_open_input(&input,argv[1],NULL,&options);av_dict_free(&options);
    Decoder video={.index=-1},audio={.index=-1};
    struct SwsContext *scale=NULL;SwrContext *resample=NULL;
    AVFrame *frame=av_frame_alloc();AVPacket *packet=av_packet_alloc();
    uint8_t *pixels=NULL;int pixels_size=0;int64_t last_video=INT64_MIN,previous_video_pts=AV_NOPTS_VALUE;
    AVChannelLayout audio_layout={0};int audio_rate=0,audio_format=-1,draining=0;
    if(!frame||!packet){result=AVERROR(ENOMEM);goto finish;}
    if(result<0)goto finish;
    if((result=avformat_find_stream_info(input,NULL))<0)goto finish;
    if((result=open_decoder(input,AVMEDIA_TYPE_VIDEO,&video))<0)goto finish;
    if(!silent) {
        int audio_result=open_decoder(input,AVMEDIA_TYPE_AUDIO,&audio);
        if(audio_result<0 && audio.index>=0) { result=audio_result;goto finish; }
    }
    result=record(STREAMS,audio.codec?1:0,0,0,0,0,0,0,(AVRational){0,1},0,NULL,0);
    if(result<0)goto finish;
    while(!stopping) {
        Decoder *decoder=NULL;
        if(!draining) {
            result=av_read_frame(input,packet);
            if(result==AVERROR_EOF)draining=1;
            else if(result<0)goto finish;
            else decoder=packet->stream_index==video.index?&video:packet->stream_index==audio.index?&audio:NULL;
        }
        if(draining) {
            decoder=draining==1?&video:draining==2?&audio:NULL;
            draining++;
            if(!decoder){result=AVERROR_EOF;break;}
        }
        if(!decoder||!decoder->codec){av_packet_unref(packet);continue;}
        result=avcodec_send_packet(decoder->codec,draining?NULL:packet);av_packet_unref(packet);
        if(result<0)goto finish;
        while((result=avcodec_receive_frame(decoder->codec,frame))>=0) {
            if(decoder==&video) {
                AVRational cadence=av_guess_frame_rate(input,video.stream,frame);
                /* Decoder frame.duration is not necessarily in the RTSP packet
                 * time base. Actual presentation deltas are the reliable cadence. */
                int64_t duration=cadence.num>0?av_rescale_q(1,av_inv_q(cadence),AV_TIME_BASE_Q):33333;
                int64_t pts=timestamp(decoder,frame,duration);
                if(previous_video_pts!=AV_NOPTS_VALUE&&pts>previous_video_pts&&pts-previous_video_pts<=2000000)duration=pts-previous_video_pts;
                previous_video_pts=pts;decoder->next_pts=pts+duration;
                if(max_fps>0&&last_video!=INT64_MIN&&pts>=last_video&&pts-last_video<1000000/max_fps){av_frame_unref(frame);continue;}
                last_video=pts;
                int width=frame->width,height=frame->height;
                if(max_width>0&&width>max_width){height=(int)((int64_t)height*max_width/width);width=max_width;}
                width=(width+1)&~1;height=(height+1)&~1;
                if(width<2||height<2||width>8192||height>8192){result=AVERROR(EINVAL);goto finish;}
                int required=av_image_get_buffer_size(AV_PIX_FMT_NV12,width,height,1);
                if(required!=pixels_size){av_freep(&pixels);pixels=av_malloc(required);pixels_size=required;}
                if(!pixels){result=AVERROR(ENOMEM);goto finish;}
                scale=sws_getCachedContext(scale,frame->width,frame->height,frame->format,width,height,AV_PIX_FMT_NV12,SWS_BILINEAR,NULL,NULL,NULL);
                if(!scale){result=AVERROR(ENOMEM);goto finish;}
                int full=frame->color_range==AVCOL_RANGE_JPEG;
                int matrix=frame->colorspace==AVCOL_SPC_BT709?1:frame->colorspace==AVCOL_SPC_BT2020_NCL?9:5;
                const int *coefficients=sws_getCoefficients(matrix==1?SWS_CS_ITU709:matrix==9?SWS_CS_BT2020:SWS_CS_ITU601);
                sws_setColorspaceDetails(scale,coefficients,full,coefficients,full,0,1<<16,1<<16);
                uint8_t *planes[4]={0};int strides[4]={0};av_image_fill_arrays(planes,strides,pixels,AV_PIX_FMT_NV12,width,height,1);
                sws_scale(scale,(const uint8_t *const *)frame->data,frame->linesize,0,frame->height,planes,strides);
                AVRational aspect=frame->sample_aspect_ratio.num>0?frame->sample_aspect_ratio:video.stream->sample_aspect_ratio;
                if(aspect.num<=0||aspect.den<=0)aspect=(AVRational){1,1};
                result=record(VIDEO,full,pts,duration,width,height,0,0,aspect,matrix,pixels,pixels_size);
            } else {
                /* One fixed interleaved format keeps the IPC and native audio queues bounded. */
                if(!resample||audio_rate!=frame->sample_rate||audio_format!=frame->format||av_channel_layout_compare(&audio_layout,&frame->ch_layout)) {
                    swr_free(&resample);av_channel_layout_uninit(&audio_layout);
                    av_channel_layout_copy(&audio_layout,&frame->ch_layout);audio_rate=frame->sample_rate;audio_format=frame->format;
                    AVChannelLayout stereo=AV_CHANNEL_LAYOUT_STEREO;
                    result=swr_alloc_set_opts2(&resample,&stereo,AV_SAMPLE_FMT_FLT,48000,&frame->ch_layout,frame->format,frame->sample_rate,0,NULL);
                    if(result<0||(result=swr_init(resample))<0)goto finish;
                }
                int64_t delay=swr_get_delay(resample,frame->sample_rate);
                int capacity=(int)av_rescale_rnd(delay+frame->nb_samples,48000,frame->sample_rate,AV_ROUND_UP);
                uint8_t *samples=NULL;int line_size=0;
                if((result=av_samples_alloc(&samples,&line_size,2,capacity,AV_SAMPLE_FMT_FLT,0))<0)goto finish;
                int count=swr_convert(resample,&samples,capacity,(const uint8_t **)frame->extended_data,frame->nb_samples);
                int64_t duration=av_rescale_q(frame->nb_samples,(AVRational){1,frame->sample_rate},AV_TIME_BASE_Q);
                int64_t pts=timestamp(decoder,frame,duration)-av_rescale_q(delay,(AVRational){1,frame->sample_rate},AV_TIME_BASE_Q);
                result=count<0?count:record(AUDIO,0,pts,av_rescale_q(count,(AVRational){1,48000},AV_TIME_BASE_Q),0,0,2,48000,(AVRational){0,1},0,samples,(size_t)count*8);
                av_freep(&samples);
            }
            av_frame_unref(frame);if(result<0)goto finish;
        }
        if(result!=AVERROR(EAGAIN)&&result!=AVERROR_EOF)goto finish;
    }
finish:
    if(result<0&&!stopping&&result!=AVERROR_EOF){char message[AV_ERROR_MAX_STRING_SIZE];av_strerror(result,message,sizeof(message));fprintf(stderr,"Local playback decoder: %s\n",message);}
    av_freep(&pixels);sws_freeContext(scale);swr_free(&resample);av_channel_layout_uninit(&audio_layout);av_frame_free(&frame);av_packet_free(&packet);
    avcodec_free_context(&video.codec);avcodec_free_context(&audio.codec);avformat_close_input(&input);avformat_network_deinit();
    return stopping||result==AVERROR_EOF?0:result<0?1:0;
}
